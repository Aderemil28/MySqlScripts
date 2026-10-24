<#
.SYNOPSIS
    Audits WinRM / remote shell activity on a list of servers, to assess the
    impact of disabling Windows Remote Shell (for example on patching, failover
    automation, schedulers and monitoring tools).

.DESCRIPTION
    For each target server, reads Microsoft-Windows-WinRM/Operational:
      Event 91  = a remote shell was created (real remote PowerShell / winrs use)
      Event 169 = a user authenticated over WinRM (shows the account)
    Remote event log reading goes over RPC, not WinRM, so this keeps working
    after the remote shell policy is applied.
    Optionally also reads the local machine's outbound WinRM sessions
    (Event 6), which shows which servers this box (for example a jump or
    staging server that runs patching) connected out to.

.PARAMETER ServerListPath
    Text file with one server name per line, or a CSV with a Server column.

.PARAMETER DaysBack
    How far back to read. WinRM logs often only keep about a week.

.PARAMETER OutputFolder
    Where CSV results are written. Pick a data drive rather than C: if the
    server list is large.

.PARAMETER IncludeOutbound
    Also export outbound WinRM sessions started from this machine.

.EXAMPLE
    .\Get-WinRMActivity.ps1 -ServerListPath .\servers.txt -DaysBack 14 -IncludeOutbound

.NOTES
    Run elevated from a management/jump server with Event Log Readers (or admin)
    rights on the targets. "RPC server unavailable" means the remote event log
    firewall rule is closed; run Get-WinEvent locally on that server instead.
    Read-only.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ServerListPath,
    [int]$DaysBack = 10,
    [string]$OutputFolder = 'C:\Temp\WinRMCheck',
    [switch]$IncludeOutbound
)

if (-not (Test-Path $OutputFolder)) { New-Item -ItemType Directory -Path $OutputFolder | Out-Null }

if ($ServerListPath -like '*.csv') {
    $servers = (Import-Csv $ServerListPath).Server
} else {
    $servers = Get-Content $ServerListPath
}
$servers = $servers | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() } | Sort-Object -Unique

$since   = (Get-Date).AddDays(-$DaysBack)
$stamp   = Get-Date -Format 'yyyyMMdd_HHmm'
$events  = New-Object System.Collections.Generic.List[object]
$status  = New-Object System.Collections.Generic.List[object]

foreach ($s in $servers) {
    Write-Host "Checking $s ..."
    try {
        $found = Get-WinEvent -ComputerName $s -FilterHashtable @{
            LogName   = 'Microsoft-Windows-WinRM/Operational'
            Id        = 91, 169
            StartTime = $since
        } -ErrorAction Stop

        foreach ($e in $found) {
            $events.Add([pscustomobject]@{
                Server      = $s
                TimeCreated = $e.TimeCreated
                EventId     = $e.Id
                Meaning     = if ($e.Id -eq 91) { 'Remote shell created' } else { 'User authenticated' }
                Message     = ($e.Message -replace '\s+', ' ')
            })
        }
        $status.Add([pscustomobject]@{ Server = $s; Result = 'OK'; Events = @($found).Count; Detail = '' })
    } catch {
        $msg = $_.Exception.Message
        $result = if ($msg -match 'No events were found') { 'OK' } else { 'Error' }
        $status.Add([pscustomobject]@{ Server = $s; Result = $result; Events = 0; Detail = $msg })
    }
}

$events | Export-Csv (Join-Path $OutputFolder "winrm_activity_$stamp.csv") -NoTypeInformation
$status | Export-Csv (Join-Path $OutputFolder "winrm_status_$stamp.csv")   -NoTypeInformation

if ($IncludeOutbound) {
    Get-WinEvent -FilterHashtable @{
        LogName   = 'Microsoft-Windows-WinRM/Operational'
        Id        = 6
        StartTime = $since
    } -ErrorAction SilentlyContinue |
        Select-Object TimeCreated, Id, @{ n = 'Message'; e = { $_.Message -replace '\s+', ' ' } } |
        Export-Csv (Join-Path $OutputFolder "winrm_outbound_$($env:COMPUTERNAME)_$stamp.csv") -NoTypeInformation
}

Write-Host "`nSummary" -ForegroundColor Cyan
$status | Format-Table -AutoSize
Write-Host "Event 91 (remote shells): $(@($events | Where-Object EventId -eq 91).Count)"
Write-Host "Event 169 (WinRM logons): $(@($events | Where-Object EventId -eq 169).Count)"
Write-Host "Results in $OutputFolder"
