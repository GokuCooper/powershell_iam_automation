<#
.SYNOPSIS
    Creates Active Directory user accounts in bulk from an HR style CSV file.

.DESCRIPTION
    Joiner automation for Active Directory. For every row in the CSV the script:
      1. Validates that the required fields are present
      2. Builds a clean username (first initial + last name)
      3. Checks the current file and AD for duplicates
      4. Creates the account in the target OU with a temporary password
      5. Adds the user to the matching department group (GRP_<Department>)

    Every row is logged, good or bad, and the results are exported to CSV so the
    whole run has an audit trail. One bad row never stops the rest of the file.

    Supports -WhatIf so every change can be previewed before anything touches AD.

.PARAMETER CsvPath
    Path to the input CSV. Required columns: FirstName, LastName, Department, Title

.PARAMETER TargetOU
    Distinguished name of the OU where the new accounts are created.

.PARAMETER UpnSuffix
    Suffix used to build the UserPrincipalName (username@suffix).

.PARAMETER GroupPrefix
    Prefix for department groups. Department "Finance" maps to group "GRP_Finance".

.EXAMPLE
    .\New-BulkADUsers.ps1 -CsvPath ..\data\new_hires.csv -WhatIf
    Preview run. Shows exactly what would happen and changes nothing in AD.

.EXAMPLE
    .\New-BulkADUsers.ps1 -CsvPath ..\data\new_hires.csv
    Live run. Prompts once for the temporary password, then creates the accounts.

.NOTES
    Author:   DeJurnett Norrington
    Project:  IAM Engineer Portfolio, Week 8 (PowerShell for IAM Automation)
    Requires: Windows PowerShell 5.1, ActiveDirectory module, rights to create users in TargetOU
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -Path $_ -PathType Leaf })]
    [string]$CsvPath,

    [string]$TargetOU = 'OU=Week8_Automation,DC=iamlab,DC=local',

    [string]$UpnSuffix = 'iamlab.local',

    [string]$GroupPrefix = 'GRP_',

    [string]$LogFolder,

    [string]$OutputFolder
)

$ErrorActionPreference = 'Stop'

# Work out the project folder here, not in the param block. Windows PowerShell 5.1 leaves
# $PSScriptRoot empty inside param defaults when a script starts with powershell.exe -File,
# which is exactly how Task Scheduler launches it. Resolving it here works both ways.
$scriptDir   = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$projectRoot = Split-Path -Parent $scriptDir
if (-not $LogFolder)    { $LogFolder    = Join-Path -Path $projectRoot -ChildPath 'logs' }
if (-not $OutputFolder) { $OutputFolder = Join-Path -Path $projectRoot -ChildPath 'output' }
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$runStamp  = Get-Date -Format 'yyyyMMdd_HHmmss'

# Log and output folders are created even during -WhatIf so a preview run still leaves a paper trail
foreach ($folder in @($LogFolder, $OutputFolder)) {
    if (-not (Test-Path -Path $folder)) {
        New-Item -Path $folder -ItemType Directory -Force -WhatIf:$false | Out-Null
    }
}
$logFile     = Join-Path -Path $LogFolder    -ChildPath "bulk_user_creation_$runStamp.log"
$resultsFile = Join-Path -Path $OutputFolder -ChildPath "bulk_user_creation_results_$runStamp.csv"

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'SUCCESS', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -Path $logFile -Value $line -WhatIf:$false
    $color = switch ($Level) {
        'SUCCESS' { 'Green' }
        'WARN'    { 'Yellow' }
        'ERROR'   { 'Red' }
        default   { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color
}

function ConvertTo-CleanName {
    param([string]$Value)
    # Letters only, lowercase. O'Brien becomes obrien, "Smith Jones" becomes smithjones
    return ($Value -replace '[^a-zA-Z]', '').ToLower()
}

$mode = if ($WhatIfPreference) { 'PREVIEW (WhatIf, nothing will be changed)' } else { 'LIVE' }
Write-Log "Bulk user creation started. Mode: $mode"
Write-Log "Input file: $CsvPath"
Write-Log "Target OU: $TargetOU"

# ---------------- Preflight checks ----------------
# Fail fast on anything that would break every row, before touching a single account.

try {
    Import-Module ActiveDirectory
}
catch {
    Write-Log 'ActiveDirectory module not found. Run this on a domain controller or install the RSAT AD tools.' -Level ERROR
    exit 1
}

try {
    Get-ADOrganizationalUnit -Identity $TargetOU | Out-Null
}
catch {
    Write-Log "Target OU not found: $TargetOU. Create it first or pass a different -TargetOU." -Level ERROR
    exit 1
}

$rows = @(Import-Csv -Path $CsvPath)
if ($rows.Count -eq 0) {
    Write-Log 'The CSV file has no data rows.' -Level ERROR
    exit 1
}

$requiredColumns = @('FirstName', 'LastName', 'Department', 'Title')
$csvColumns      = $rows[0].PSObject.Properties.Name
$missingColumns  = @($requiredColumns | Where-Object { $csvColumns -notcontains $_ })
if ($missingColumns.Count -gt 0) {
    Write-Log "CSV is missing required column(s): $($missingColumns -join ', ')" -Level ERROR
    exit 1
}

Write-Log "Preflight checks passed. $($rows.Count) row(s) to process."

# The temporary password is asked for once and never written to the script, the log, or the CSV
$tempPassword = $null
if (-not $WhatIfPreference) {
    $tempPassword = Read-Host -Prompt 'Enter the temporary password for new accounts' -AsSecureString
    if ($tempPassword.Length -eq 0) {
        Write-Log 'No temporary password entered. Stopping.' -Level ERROR
        exit 1
    }
}

# Restart the clock so the run time measures the script's work, not how long a human took to type
$stopwatch.Restart()

# ---------------- Process each row ----------------

$results     = New-Object System.Collections.Generic.List[object]
$seenThisRun = New-Object System.Collections.Generic.HashSet[string]
$rowNumber   = 1   # row 1 is the header, so the first person is row 2 (matches what you see in Excel)

foreach ($row in $rows) {
    $rowNumber++
    $first = "$($row.FirstName)".Trim()
    $last  = "$($row.LastName)".Trim()
    $dept  = "$($row.Department)".Trim()
    $title = "$($row.Title)".Trim()

    $result = [ordered]@{
        Row            = $rowNumber
        FirstName      = $first
        LastName       = $last
        Department     = $dept
        SamAccountName = ''
        Status         = 'FAILED'
        Detail         = ''
    }

    try {
        if (-not $first -or -not $last -or -not $dept) {
            throw 'Missing a required value. FirstName, LastName, and Department cannot be blank.'
        }

        $cleanFirst = ConvertTo-CleanName $first
        $cleanLast  = ConvertTo-CleanName $last
        if (-not $cleanFirst -or -not $cleanLast) {
            throw 'Name has no usable letters after cleanup.'
        }

        # Username rule: first initial + last name, capped at 20 characters (the sAMAccountName limit)
        $sam = $cleanFirst.Substring(0, 1) + $cleanLast
        if ($sam.Length -gt 20) { $sam = $sam.Substring(0, 20) }
        $result.SamAccountName = $sam

        # Duplicate check 1: the same person appears twice in this file
        if ($seenThisRun.Contains($sam)) {
            $result.Status = 'SKIPPED'
            $result.Detail = 'Duplicate of an earlier row in this same file.'
            Write-Log "Row $rowNumber skipped. $sam appears earlier in this file." -Level WARN
            continue
        }
        [void]$seenThisRun.Add($sam)

        # Duplicate check 2: the username already exists in AD.
        # Skipping (instead of auto numbering like jsmith2) is on purpose. A collision can mean a
        # rehire, two different people, or a double request, and a human should make that call.
        $existing = Get-ADUser -Filter "SamAccountName -eq '$sam'"
        if ($existing) {
            $result.Status = 'SKIPPED'
            $result.Detail = "Username already exists in AD at $($existing.DistinguishedName). Needs a human decision: rehire, name collision, or duplicate request."
            Write-Log "Row $rowNumber skipped. $sam already exists in AD." -Level WARN
            continue
        }

        $userParams = @{
            Name                  = "$first $last"
            GivenName             = $first
            Surname               = $last
            DisplayName           = "$first $last"
            SamAccountName        = $sam
            UserPrincipalName     = "$sam@$UpnSuffix"
            Department            = $dept
            Path                  = $TargetOU
            AccountPassword       = $tempPassword
            ChangePasswordAtLogon = $true
            Enabled               = $true
        }
        if ($title) { $userParams.Title = $title }

        if (-not $PSCmdlet.ShouldProcess("$first $last ($sam)", "Create AD user in $TargetOU")) {
            $result.Status = 'PREVIEW'
            $result.Detail = 'WhatIf run. This account would be created.'
            continue
        }

        New-ADUser @userParams
        $result.Status = 'CREATED'
        $result.Detail = 'Account created'
        Write-Log "Row $rowNumber created $sam ($first $last, $dept)." -Level SUCCESS

        # Birthright access: add the user to their department group if it exists.
        # This has its own try/catch so a group problem never marks a created account as FAILED.
        $groupName = $GroupPrefix + ($dept -replace '[^a-zA-Z0-9]', '')
        try {
            $group = Get-ADGroup -Filter "Name -eq '$groupName'"
            if ($group) {
                Add-ADGroupMember -Identity $group -Members $sam
                $result.Detail += "; added to $groupName"
                Write-Log "  Added $sam to $groupName." -Level SUCCESS
            }
            else {
                $result.Status  = 'CREATED_WITH_WARNING'
                $result.Detail += "; no group named $groupName so no department access was assigned"
                Write-Log "  No group named $groupName. Account created without department access." -Level WARN
            }
        }
        catch {
            $result.Status  = 'CREATED_WITH_WARNING'
            $result.Detail += "; group add failed: $($_.Exception.Message)"
            Write-Log "  Group add failed for $sam. $($_.Exception.Message)" -Level WARN
        }
    }
    catch {
        $result.Status = 'FAILED'
        $result.Detail = $_.Exception.Message
        Write-Log "Row $rowNumber failed. $($_.Exception.Message)" -Level ERROR

        # New-ADUser can leave a half built, disabled account behind when AD rejects the password.
        # Check for that so nobody gets surprised by a ghost account later.
        if ($result.SamAccountName -and -not $WhatIfPreference) {
            $partial = $null
            try { $partial = Get-ADUser -Filter "SamAccountName -eq '$($result.SamAccountName)'" } catch { }
            if ($partial) {
                $result.Detail += "; an account named $($result.SamAccountName) exists anyway (Enabled: $($partial.Enabled)). Review it before rerunning."
                Write-Log "  Heads up: $($result.SamAccountName) exists in AD after the failure. Check it by hand." -Level WARN
            }
        }
    }
    finally {
        $results.Add([pscustomobject]$result)
    }
}

# ---------------- Summary ----------------

$results | Export-Csv -Path $resultsFile -NoTypeInformation -WhatIf:$false
$stopwatch.Stop()

$created = @($results | Where-Object { $_.Status -like 'CREATED*' }).Count
$skipped = @($results | Where-Object { $_.Status -eq 'SKIPPED' }).Count
$failed  = @($results | Where-Object { $_.Status -eq 'FAILED' }).Count
$preview = @($results | Where-Object { $_.Status -eq 'PREVIEW' }).Count

Write-Log ('Run complete in {0:N1} seconds. Rows: {1} | Created: {2} | Skipped: {3} | Failed: {4} | Preview: {5}' -f `
    $stopwatch.Elapsed.TotalSeconds, $results.Count, $created, $skipped, $failed, $preview)
Write-Log "Results file: $resultsFile"
Write-Log "Log file: $logFile"

# Exit codes let Task Scheduler or another script know how the run went: 0 = clean, 2 = some rows failed
if ($failed -gt 0) { exit 2 } else { exit 0 }
