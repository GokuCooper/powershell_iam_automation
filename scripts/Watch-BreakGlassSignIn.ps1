<#
.SYNOPSIS
    Alerts when an emergency (break glass) account signs in to Microsoft Entra ID.

.DESCRIPTION
    Break glass accounts are excluded from Conditional Access so the organization can
    never lock itself out. That makes them the most dangerous accounts in the tenant,
    so every sign in, successful or failed, should raise an alert.

    This script pulls the Entra ID sign in logs through Microsoft Graph, looks for any
    activity on the break glass account(s) inside the lookback window, and when it finds
    some it:
      1. Prints a red alert in the console
      2. Writes the alert to the log file
      3. Writes a Warning event to the Windows Application log (Event ID 9001 or 9002)
      4. Exports every matching sign in to CSV as evidence

    This closes out CA005 from Week 7 at $0, with no Azure subscription or Log Analytics.

    Known limitation (on purpose for Week 8):
    It signs in to Graph as you (delegated, interactive). To run unattended on a schedule
    it needs an app registration with a certificate, which is the Week 9 upgrade.

.PARAMETER BreakGlassUpn
    One or more break glass account UPNs to watch.

.PARAMETER LookbackHours
    How far back to search the sign in logs. Default 24 hours.

.PARAMETER TenantId
    Optional tenant ID or domain, useful when your account can see more than one tenant.

.EXAMPLE
    .\Watch-BreakGlassSignIn.ps1 -BreakGlassUpn 'breakglass01@contoso.onmicrosoft.com'

.EXAMPLE
    .\Watch-BreakGlassSignIn.ps1 -BreakGlassUpn 'bg01@contoso.onmicrosoft.com','bg02@contoso.onmicrosoft.com' -LookbackHours 72

.NOTES
    Author:   DeJurnett Norrington
    Project:  IAM Engineer Portfolio, Week 8 (PowerShell for IAM Automation)
    Requires: Windows PowerShell 5.1, Microsoft.Graph.Authentication, Microsoft.Graph.Reports,
              Entra ID P1 or P2 (sign in logs through Graph are a premium feature),
              AuditLog.Read.All and Directory.Read.All consented
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$BreakGlassUpn,

    [ValidateRange(1, 720)]
    [int]$LookbackHours = 24,

    [string]$TenantId,

    [string]$EventSource = 'IAM_BreakGlass_Monitor',

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
$runStamp = Get-Date -Format 'yyyyMMdd_HHmmss'

foreach ($folder in @($LogFolder, $OutputFolder)) {
    if (-not (Test-Path -Path $folder)) {
        New-Item -Path $folder -ItemType Directory -Force | Out-Null
    }
}
$logFile     = Join-Path -Path $LogFolder    -ChildPath "break_glass_monitor_$runStamp.log"
$evidenceCsv = Join-Path -Path $OutputFolder -ChildPath "break_glass_signins_$runStamp.csv"

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'SUCCESS', 'WARN', 'ERROR', 'ALERT')][string]$Level = 'INFO'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -Path $logFile -Value $line
    $color = switch ($Level) {
        'SUCCESS' { 'Green' }
        'WARN'    { 'Yellow' }
        'ERROR'   { 'Red' }
        'ALERT'   { 'Magenta' }
        default   { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color
}

function Write-AlertEvent {
    param([int]$EventId, [string]$Message)
    try {
        # Registering an event source needs an elevated (Run as administrator) window the first time
        if (-not [System.Diagnostics.EventLog]::SourceExists($EventSource)) {
            New-EventLog -LogName Application -Source $EventSource
        }
        Write-EventLog -LogName Application -Source $EventSource -EventId $EventId -EntryType Warning -Message $Message
        Write-Log "Windows Application log event $EventId written (source $EventSource)."
    }
    catch {
        Write-Log "Could not write to the Windows Event Log. Run PowerShell as Administrator once so the source can be registered. $($_.Exception.Message)" -Level WARN
    }
}

# ---------------- Preflight ----------------

foreach ($module in @('Microsoft.Graph.Authentication', 'Microsoft.Graph.Reports')) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Write-Log "Module $module is not installed. Run: Install-Module $module -Scope CurrentUser" -Level ERROR
        exit 1
    }
}
Import-Module Microsoft.Graph.Authentication
Import-Module Microsoft.Graph.Reports

$requiredScopes = @('AuditLog.Read.All', 'Directory.Read.All')
$context = Get-MgContext
$needsConnect = (-not $context)
if ($context) {
    foreach ($scope in $requiredScopes) {
        if ($context.Scopes -notcontains $scope) { $needsConnect = $true }
    }
}

if ($needsConnect) {
    Write-Log 'Connecting to Microsoft Graph. A browser sign in window will open.'
    $connectParams = @{ Scopes = $requiredScopes; NoWelcome = $true }
    if ($TenantId) { $connectParams.TenantId = $TenantId }
    try {
        Connect-MgGraph @connectParams
    }
    catch {
        Write-Log "Could not connect to Microsoft Graph. $($_.Exception.Message)" -Level ERROR
        exit 1
    }
}
$context = Get-MgContext
Write-Log "Connected to tenant $($context.TenantId) as $($context.Account)."

# ---------------- Check the sign in logs ----------------

$sinceUtc = (Get-Date).ToUniversalTime().AddHours(-$LookbackHours)
$sinceIso = $sinceUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
Write-Log "Checking $($BreakGlassUpn.Count) break glass account(s) for sign ins since $sinceIso (last $LookbackHours hours)."

$evidence = New-Object System.Collections.Generic.List[object]

foreach ($upn in $BreakGlassUpn) {
    $filter = "userPrincipalName eq '$upn' and createdDateTime ge $sinceIso"
    try {
        $signIns = @(Get-MgAuditLogSignIn -Filter $filter -All)
    }
    catch {
        Write-Log "Sign in log query failed for $upn. $($_.Exception.Message)" -Level ERROR
        continue
    }

    if ($signIns.Count -eq 0) {
        Write-Log "No sign ins found for $upn. All quiet." -Level SUCCESS
        continue
    }

    foreach ($s in $signIns) {
        $result = if ($s.Status.ErrorCode -eq 0) { 'Success' } else { "Failure ($($s.Status.ErrorCode)): $($s.Status.FailureReason)" }
        $evidence.Add([pscustomobject][ordered]@{
            TimeLocal               = $s.CreatedDateTime.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
            UserPrincipalName       = $s.UserPrincipalName
            Result                  = $result
            Application             = $s.AppDisplayName
            ClientApp               = $s.ClientAppUsed
            IPAddress               = $s.IPAddress
            City                    = $s.Location.City
            Country                 = $s.Location.CountryOrRegion
            ConditionalAccessStatus = $s.ConditionalAccessStatus
            SignInId                = $s.Id
        })
    }

    $successCount = @($signIns | Where-Object { $_.Status.ErrorCode -eq 0 }).Count
    $failCount    = $signIns.Count - $successCount
    $latest       = $signIns | Sort-Object CreatedDateTime -Descending | Select-Object -First 1

    Write-Host ''
    Write-Host '==================== BREAK GLASS ALERT ====================' -ForegroundColor Magenta
    Write-Log "$upn has $($signIns.Count) sign in(s) in the last $LookbackHours hours. Successful: $successCount. Failed: $failCount." -Level ALERT
    Write-Log "Most recent: $($latest.CreatedDateTime.ToLocalTime()) from $($latest.IPAddress) into $($latest.AppDisplayName)." -Level ALERT
    Write-Host '===========================================================' -ForegroundColor Magenta
    Write-Host ''

    # 9001 = the account was actually used (highest severity). 9002 = only failed attempts (someone is trying).
    $eventId = if ($successCount -gt 0) { 9001 } else { 9002 }
    $message = "Break glass account $upn signed in. Sign ins in the last $LookbackHours hours: $($signIns.Count) (successful $successCount, failed $failCount). " +
               "Most recent: $($latest.CreatedDateTime.ToLocalTime()) from IP $($latest.IPAddress) into $($latest.AppDisplayName). " +
               "Confirm this was an approved emergency use. If not, treat it as an incident."
    Write-AlertEvent -EventId $eventId -Message $message
}

if ($evidence.Count -gt 0) {
    $evidence | Export-Csv -Path $evidenceCsv -NoTypeInformation
    Write-Log "Evidence saved: $evidenceCsv" -Level WARN
    Write-Log "Log file: $logFile"
    exit 3   # 3 = alert raised, so a scheduler or wrapper can react to it
}

Write-Log "Log file: $logFile"
exit 0
