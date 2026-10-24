<#
.SYNOPSIS
    Lists every SQL Server related Windows service and the account it runs as,
    across a list of servers.

.DESCRIPTION
    Covers the engine, Agent, SSRS, SSIS, SSAS, Browser and Full-Text launcher.
    Tries CIM over WinRM first and falls back to CIM over DCOM, so it still works
    where remote shell / WinRM is restricted. Unreachable servers are reported,
    not silently skipped.
    Typical uses: service account inventories for Kerberos/encryption-type
    remediation, password rotations, and audit requests.

.PARAMETER ServerListPath
    Text file with one server name per line.

.PARAMETER OutputPath
    CSV report path.

.EXAMPLE
    .\Get-SqlServiceAccounts.ps1 -ServerListPath .\nonprod.txt
    Import-Csv C:\Temp\sql_service_accounts.csv | Select-Object -Unique Account

.NOTES
    Run from a management/jump server with admin rights on the targets. Read-only.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ServerListPath,
    [string]$OutputPath = 'C:\Temp\sql_service_accounts.csv'
)

$pattern = 'MSSQL|SQLAgent|SQLSERVERAGENT|ReportServer|SQLServerReportingServices|PowerBIReportServer|MsDtsServer|SQLBrowser|MSSQLFDLauncher|MSOLAP|SQLTELEMETRY|SSISTELEMETRY|Launchpad'
$servers = Get-Content $ServerListPath | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() } | Sort-Object -Unique

$results = foreach ($s in $servers) {
    $session = $null
    $proto   = $null
    foreach ($p in 'Wsman', 'Dcom') {
        try {
            $opt     = New-CimSessionOption -Protocol $p
            $session = New-CimSession -ComputerName $s -SessionOption $opt -OperationTimeoutSec 30 -ErrorAction Stop
            $proto   = $p
            break
        } catch { Write-Verbose "$s : $p failed, trying next protocol" }
    }

    if (-not $session) {
        [pscustomobject]@{ Server = $s; Service = ''; DisplayName = ''; Account = ''; State = ''; StartMode = ''; Protocol = ''; Note = 'Unreachable (WinRM and DCOM)' }
        continue
    }

    try {
        Get-CimInstance -CimSession $session -ClassName Win32_Service -ErrorAction Stop |
            Where-Object { $_.Name -match $pattern } |
            ForEach-Object {
                [pscustomobject]@{
                    Server      = $s
                    Service     = $_.Name
                    DisplayName = $_.DisplayName
                    Account     = $_.StartName
                    State       = $_.State
                    StartMode   = $_.StartMode
                    Protocol    = $proto
                    Note        = ''
                }
            }
    } catch {
        [pscustomobject]@{ Server = $s; Service = ''; DisplayName = ''; Account = ''; State = ''; StartMode = ''; Protocol = $proto; Note = $_.Exception.Message }
    } finally {
        Remove-CimSession $session
    }
}

$outDir = Split-Path $OutputPath
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
$results | Export-Csv $OutputPath -NoTypeInformation

Write-Host "Saved to $OutputPath"
Write-Host "`nDistinct accounts:" -ForegroundColor Cyan
$results | Where-Object Account | Group-Object Account | Sort-Object Count -Descending |
    Select-Object @{ n = 'Account'; e = { $_.Name } }, @{ n = 'Services'; e = { $_.Count } } | Format-Table -AutoSize
