<#
.SYNOPSIS
    Reports Active Directory accounts that have not signed in for a set number of days.

.DESCRIPTION
    Finds two kinds of risky accounts:
      INACTIVE         The account has signed in before, but not within the threshold.
      NEVER_LOGGED_IN  The account has never signed in and is older than the threshold.

    Brand new accounts that have not signed in yet are NOT flagged. A new hire who
    starts next Monday is not a security problem, and flagging them would bury the
    real findings in noise.

    This script is read only on purpose. It produces evidence for a human to review.
    Disabling accounts is a separate, approved step, not something a report should do
    on its own.

    About the timestamp:
    AD keeps two "last logon" values. lastLogon is exact but lives on each domain
    controller separately. lastLogonTimestamp is copied to every domain controller,
    but AD only refreshes it about every 9 to 14 days to save network traffic.
    This script uses lastLogonTimestamp because it is the same everywhere. A 14 day
    lag does not matter when the question is "has this person been gone for 90 days".

.PARAMETER DaysInactive
    How many days without a sign in counts as inactive. Default 90.

.PARAMETER SearchBase
    Optional OU to limit the search to. Default is the whole domain.

.PARAMETER ExcludeSamAccountName
    Accounts to leave out of the report, such as built in service accounts.

.PARAMETER IncludeDisabled
    Also check accounts that are already disabled. Off by default.

.EXAMPLE
    .\Get-InactiveADUsers.ps1
    Standard 90 day report for the whole domain.

.EXAMPLE
    .\Get-InactiveADUsers.ps1 -DaysInactive 7
    Short threshold used in the lab to prove the logic works on young test accounts.

.NOTES
    Author:   DeJurnett Norrington
    Project:  IAM Engineer Portfolio, Week 8 (PowerShell for IAM Automation)
    Requires: Windows PowerShell 5.1, ActiveDirectory module, read access to AD
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 3650)]
    [int]$DaysInactive = 90,

    [string]$SearchBase,

    [string[]]$ExcludeSamAccountName = @('krbtgt', 'Guest'),

    [switch]$IncludeDisabled,

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

foreach ($folder in @($LogFolder, $OutputFolder)) {
    if (-not (Test-Path -Path $folder)) {
        New-Item -Path $folder -ItemType Directory -Force | Out-Null
    }
}
$logFile    = Join-Path -Path $LogFolder    -ChildPath "inactive_accounts_$runStamp.log"
$reportFile = Join-Path -Path $OutputFolder -ChildPath "inactive_accounts_${DaysInactive}_days_$runStamp.csv"

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'SUCCESS', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -Path $logFile -Value $line
    $color = switch ($Level) {
        'SUCCESS' { 'Green' }
        'WARN'    { 'Yellow' }
        'ERROR'   { 'Red' }
        default   { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color
}

try {
    Import-Module ActiveDirectory
}
catch {
    Write-Log 'ActiveDirectory module not found. Run this on a domain controller or install the RSAT AD tools.' -Level ERROR
    exit 1
}

$now    = Get-Date
$cutoff = $now.AddDays(-$DaysInactive)
Write-Log "Inactive account report started. Threshold: $DaysInactive days (no sign in since $($cutoff.ToString('yyyy-MM-dd')))."

$getParams = @{
    Filter     = '*'
    Properties = @('LastLogonTimestamp', 'whenCreated', 'Department', 'Title', 'Manager', 'Enabled')
}
if (-not $IncludeDisabled) { $getParams.Filter = 'Enabled -eq $true' }
if ($SearchBase) {
    $getParams.SearchBase = $SearchBase
    Write-Log "Search limited to: $SearchBase"
}

try {
    $users = @(Get-ADUser @getParams)
}
catch {
    Write-Log "Could not read users from AD. $($_.Exception.Message)" -Level ERROR
    exit 1
}
Write-Log "$($users.Count) account(s) in scope."

$managerCache  = @{}   # look each manager up once, not once per employee
$report        = New-Object System.Collections.Generic.List[object]
$activeCount   = 0
$tooNewCount   = 0
$excludedCount = 0

foreach ($u in $users) {
    if ($ExcludeSamAccountName -contains $u.SamAccountName) {
        $excludedCount++
        continue
    }

    $lastLogon = $null
    if ($u.LastLogonTimestamp) {
        $lastLogon = [DateTime]::FromFileTime($u.LastLogonTimestamp)
    }

    $accountAgeDays = [int]($now - $u.whenCreated).TotalDays

    if ($lastLogon) {
        if ($lastLogon -ge $cutoff) {
            $activeCount++
            continue
        }
        $finding       = 'INACTIVE'
        $daysSince     = [int]($now - $lastLogon).TotalDays
        $lastLogonText = $lastLogon.ToString('yyyy-MM-dd')
    }
    else {
        # Never signed in. Only flag it if the account is older than the threshold.
        if ($u.whenCreated -ge $cutoff) {
            $tooNewCount++
            continue
        }
        $finding       = 'NEVER_LOGGED_IN'
        $daysSince     = ''
        $lastLogonText = 'Never'
    }

    $managerName = ''
    if ($u.Manager) {
        if (-not $managerCache.ContainsKey($u.Manager)) {
            try   { $managerCache[$u.Manager] = (Get-ADUser -Identity $u.Manager).Name }
            catch { $managerCache[$u.Manager] = 'Manager record not found' }
        }
        $managerName = $managerCache[$u.Manager]
    }

    $report.Add([pscustomobject][ordered]@{
        SamAccountName    = $u.SamAccountName
        DisplayName       = $u.Name
        Department        = $u.Department
        Title             = $u.Title
        Manager           = $managerName
        Enabled           = $u.Enabled
        Finding           = $finding
        LastLogon         = $lastLogonText
        DaysSinceLogon    = $daysSince
        AccountCreated    = $u.whenCreated.ToString('yyyy-MM-dd')
        AccountAgeDays    = $accountAgeDays
        DistinguishedName = $u.DistinguishedName
    })
}

$stopwatch.Stop()
$inactiveCount = @($report | Where-Object { $_.Finding -eq 'INACTIVE' }).Count
$neverCount    = @($report | Where-Object { $_.Finding -eq 'NEVER_LOGGED_IN' }).Count

if ($report.Count -gt 0) {
    $report |
        Sort-Object -Property Finding, @{ Expression = 'AccountAgeDays'; Descending = $true } |
        Export-Csv -Path $reportFile -NoTypeInformation
    Write-Log "Report saved: $reportFile" -Level SUCCESS
}
else {
    Write-Log 'No accounts matched the threshold. That is a clean result, not an error.' -Level SUCCESS
}

Write-Log ('Summary: In scope {0} | Active {1} | Inactive {2} | Never logged in {3} | Too new to judge {4} | Excluded {5} | Run time {6:N1}s' -f `
    $users.Count, $activeCount, $inactiveCount, $neverCount, $tooNewCount, $excludedCount, $stopwatch.Elapsed.TotalSeconds)
Write-Log "Log file: $logFile"

exit 0
