<#
.SYNOPSIS
    Audits Active Directory group membership and flags risky access.

.DESCRIPTION
    Lists who is in every group, including people who get in through a nested group,
    and flags the findings an auditor would ask about:

      DISABLED_ACCOUNT_STILL_A_MEMBER     A disabled user still holds the group's access.
                                          Classic sign of a Leaver that was only half finished.
      PRIVILEGED_ACCESS                   A user is in a high power group like Domain Admins.
      NESTED_GROUP_IN_PRIVILEGED_GROUP    A whole group sits inside a privileged group, so
                                          everyone in it quietly inherits admin rights.
      EMPTY_GROUP                         A group with no members. Usually clutter to clean up.

    Two CSV files are produced: the full membership list and a findings only list
    that can go straight into an audit evidence package.

.PARAMETER SearchBase
    Optional OU to limit which groups are audited. Default is the whole domain.

.PARAMETER GroupNameFilter
    Optional name filter, for example 'GRP_*'. Default is every group.

.PARAMETER ExcludeGroup
    Groups left out because every account is in them (pure noise in a report).

.PARAMETER PrivilegedGroup
    Groups treated as privileged. Anyone in these gets flagged.

.EXAMPLE
    .\Get-ADGroupMembershipAudit.ps1
    Audit every group in the domain.

.EXAMPLE
    .\Get-ADGroupMembershipAudit.ps1 -SearchBase 'OU=Week8_Automation,DC=iamlab,DC=local'
    Audit only the groups in one OU.

.NOTES
    Author:   DeJurnett Norrington
    Project:  IAM Engineer Portfolio, Week 8 (PowerShell for IAM Automation)
    Requires: Windows PowerShell 5.1, ActiveDirectory module, read access to AD
#>
[CmdletBinding()]
param(
    [string]$SearchBase,

    [string]$GroupNameFilter = '*',

    [string[]]$ExcludeGroup = @(
        'Domain Users', 'Domain Computers', 'Domain Controllers', 'Domain Guests',
        'Read-only Domain Controllers', 'Enterprise Read-only Domain Controllers',
        'Cloneable Domain Controllers'
    ),

    [string[]]$PrivilegedGroup = @(
        'Domain Admins', 'Enterprise Admins', 'Schema Admins', 'Administrators',
        'Account Operators', 'Backup Operators', 'Server Operators', 'Print Operators',
        'Group Policy Creator Owners', 'DnsAdmins'
    ),

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
$logFile      = Join-Path -Path $LogFolder    -ChildPath "group_membership_audit_$runStamp.log"
$fullFile     = Join-Path -Path $OutputFolder -ChildPath "group_membership_audit_full_$runStamp.csv"
$findingsFile = Join-Path -Path $OutputFolder -ChildPath "group_membership_audit_findings_$runStamp.csv"

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

$userCache = @{}   # look each user up once, even if they are in 20 groups
function Get-UserDetail {
    param([string]$DistinguishedName)
    if (-not $userCache.ContainsKey($DistinguishedName)) {
        try   { $userCache[$DistinguishedName] = Get-ADUser -Identity $DistinguishedName -Properties Enabled, Department }
        catch { $userCache[$DistinguishedName] = $null }
    }
    return $userCache[$DistinguishedName]
}

function New-AuditRow {
    param(
        $Group, [bool]$IsPrivileged, $MemberName, $MemberSam, $MemberType,
        $MembershipType, $MemberEnabled, $MemberDepartment, $Finding, $Note
    )
    [pscustomobject][ordered]@{
        GroupName            = $Group.Name
        GroupScope           = "$($Group.GroupScope)"
        GroupCategory        = "$($Group.GroupCategory)"
        PrivilegedGroup      = if ($IsPrivileged) { 'Yes' } else { 'No' }
        MemberName           = $MemberName
        MemberSamAccountName = $MemberSam
        MemberType           = $MemberType
        MembershipType       = $MembershipType
        MemberEnabled        = $MemberEnabled
        MemberDepartment     = $MemberDepartment
        Finding              = $Finding
        Note                 = $Note
    }
}

try {
    Import-Module ActiveDirectory
}
catch {
    Write-Log 'ActiveDirectory module not found. Run this on a domain controller or install the RSAT AD tools.' -Level ERROR
    exit 1
}

Write-Log 'Group membership audit started.'

$groupParams = @{
    Filter     = "Name -like '$GroupNameFilter'"
    Properties = @('Members')
}
if ($SearchBase) {
    $groupParams.SearchBase = $SearchBase
    Write-Log "Search limited to: $SearchBase"
}

try {
    $groups = @(Get-ADGroup @groupParams | Where-Object { $ExcludeGroup -notcontains $_.Name } | Sort-Object Name)
}
catch {
    Write-Log "Could not read groups from AD. $($_.Exception.Message)" -Level ERROR
    exit 1
}
Write-Log "$($groups.Count) group(s) to audit."

$rows            = New-Object System.Collections.Generic.List[object]
$emptyGroups     = 0
$disabledMembers = 0
$privMembers     = 0
$fallbackGroups  = 0

foreach ($g in $groups) {
    $isPrivileged = $PrivilegedGroup -contains $g.Name
    $note         = ''

    try {
        $direct = @(Get-ADGroupMember -Identity $g)
        $leaf   = @(Get-ADGroupMember -Identity $g -Recursive)
    }
    catch {
        # Get-ADGroupMember is known to fail on some built in groups, usually ones holding
        # foreign security principals like "Authenticated Users". Instead of losing the group,
        # read its raw Members attribute. That gives direct members only, and the note says so.
        $fallbackGroups++
        $note = 'Get-ADGroupMember failed; used raw Members attribute (direct members only)'
        Write-Log "Get-ADGroupMember failed on '$($g.Name)': $($_.Exception.Message) Falling back to the raw Members attribute." -Level WARN
        $direct = @(foreach ($dn in $g.Members) {
            try { Get-ADObject -Identity $dn -Properties sAMAccountName } catch { }
        })
        $leaf = @($direct | Where-Object { $_.ObjectClass -ne 'group' })
    }

    if ($direct.Count -eq 0) {
        $emptyGroups++
        $rows.Add((New-AuditRow -Group $g -IsPrivileged $isPrivileged -MemberName '(none)' -Finding 'EMPTY_GROUP' -Note $note))
        continue
    }

    $directDNs = @($direct | ForEach-Object { $_.DistinguishedName })

    # Groups sitting directly inside this group
    foreach ($m in @($direct | Where-Object { $_.ObjectClass -eq 'group' })) {
        $finding = if ($isPrivileged) { 'NESTED_GROUP_IN_PRIVILEGED_GROUP' } else { '' }
        $rows.Add((New-AuditRow -Group $g -IsPrivileged $isPrivileged -MemberName $m.Name -MemberSam $m.SamAccountName `
            -MemberType 'group' -MembershipType 'Direct' -Finding $finding -Note $note))
    }

    # Every user or computer that ends up with this group's access, directly or through nesting
    foreach ($m in $leaf) {
        $membership = if ($directDNs -contains $m.DistinguishedName) { 'Direct' } else { 'Nested' }
        $enabled    = ''
        $department = ''
        $findings   = @()

        if ($m.ObjectClass -eq 'user') {
            $detail = Get-UserDetail -DistinguishedName $m.DistinguishedName
            if ($detail) {
                $enabled    = $detail.Enabled
                $department = $detail.Department
                if (-not $detail.Enabled) {
                    $findings += 'DISABLED_ACCOUNT_STILL_A_MEMBER'
                    $disabledMembers++
                }
            }
            if ($isPrivileged) {
                $findings += 'PRIVILEGED_ACCESS'
                $privMembers++
            }
        }

        $rows.Add((New-AuditRow -Group $g -IsPrivileged $isPrivileged -MemberName $m.Name -MemberSam $m.SamAccountName `
            -MemberType $m.ObjectClass -MembershipType $membership -MemberEnabled $enabled `
            -MemberDepartment $department -Finding ($findings -join '; ') -Note $note))
    }
}

$rows | Export-Csv -Path $fullFile -NoTypeInformation
$findingRows = @($rows | Where-Object { $_.Finding })
if ($findingRows.Count -gt 0) {
    $findingRows | Export-Csv -Path $findingsFile -NoTypeInformation
    Write-Log "Findings file: $findingsFile" -Level WARN
}
else {
    Write-Log 'No findings. Every member is enabled and no privileged access was found.' -Level SUCCESS
}

$stopwatch.Stop()
Write-Log ('Summary: Groups {0} | Membership rows {1} | Disabled members {2} | Privileged memberships {3} | Empty groups {4} | Fallback groups {5} | Run time {6:N1}s' -f `
    $groups.Count, $rows.Count, $disabledMembers, $privMembers, $emptyGroups, $fallbackGroups, $stopwatch.Elapsed.TotalSeconds)
Write-Log "Full membership file: $fullFile" -Level SUCCESS
Write-Log "Log file: $logFile"

exit 0
