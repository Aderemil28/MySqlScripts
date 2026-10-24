<#
.SYNOPSIS
    Checks whether a Windows service is installed and running on a list of
    servers, for example to confirm an agent (monitoring, logging, security)
    is deployed everywhere a CMDB export says it should be.

.DESCRIPTION
    Reads servers from a text file or a CSV export (CMDB, inventory), optionally
    skips servers already confirmed by someone else, and checks the service with
    Get-Service over RPC. RPC does not need WinRM, so it works where remote shell
    is disabled. Each server is reported as Running, Stopped (or other state),
    NotInstalled, Unreachable or AccessDenied.
    Servers on the confirmed list that are missing from the main list are
    reported too, which catches inventory gaps.

.PARAMETER ServerListPath
    Text file (one name per line) or CSV.

.PARAMETER ServerColumn
    Column holding the server name when ServerListPath is a CSV.

.PARAMETER ConfirmedListPath
    Optional text file of servers already confirmed. They are skipped.

.PARAMETER ServiceName
    Service key name or display name. Wildcards are allowed (for example '*Monitor*').

.EXAMPLE
    .\Test-ServiceStatus.ps1 -ServerListPath .\cmdb_export.csv -ServerColumn Name -ServiceName 'W32Time'
    .\Test-ServiceStatus.ps1 -ServerListPath .\servers.txt -ConfirmedListPath .\confirmed.txt -ServiceName '*agent*'

.NOTES
    Windows PowerShell 5.1 (Get-Service -ComputerName was removed in PowerShell 7).
    Read-only.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ServerListPath,
    [string]$ServerColumn = 'Name',
    [string]$ConfirmedListPath,
    [Parameter(Mandatory)][string]$ServiceName,
    [string]$OutputPath = 'C:\Temp\service_status.csv'
)

if ($PSVersionTable.PSVersion.Major -gt 5) {
    Write-Warning 'Run this in Windows PowerShell 5.1. Get-Service -ComputerName does not exist in PowerShell 7.'
    return
}

function Get-NameList([string]$Path, [string]$Column) {
    if ($Path -like '*.csv') { (Import-Csv $Path).$Column } else { Get-Content $Path }
}

$all = Get-NameList $ServerListPath $ServerColumn |
       Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim().ToUpper() } | Sort-Object -Unique

$confirmed = @()
if ($ConfirmedListPath) {
    $confirmed = Get-NameList $ConfirmedListPath $ServerColumn |
                 Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim().ToUpper() } | Sort-Object -Unique
}

$toCheck = $all | Where-Object { $_ -notin $confirmed }
Write-Host "In list: $(@($all).Count)  Already confirmed: $(@($confirmed).Count)  To check: $(@($toCheck).Count)"

$results = foreach ($s in $toCheck) {
    $status = $null
    $detail = ''
    if (-not (Test-Connection -ComputerName $s -Count 1 -Quiet)) {
        # ICMP may be blocked; still try RPC before giving up
        $detail = 'No ping reply'
    }
    try {
        $svc = Get-Service -ComputerName $s -ErrorAction Stop |
               Where-Object { $_.Name -like $ServiceName -or $_.DisplayName -like $ServiceName } |
               Select-Object -First 1
        if ($svc) { $status = "$($svc.Status)"; $detail = "$($svc.Name) / $($svc.DisplayName)" }
        else      { $status = 'NotInstalled' }
    } catch {
        $m = $_.Exception.Message
        if ($m -match 'Access is denied|access denied') { $status = 'AccessDenied' }
        else                                             { $status = 'Unreachable' }
        $detail = $m
    }
    [pscustomobject]@{ Server = $s; Status = $status; Detail = $detail }
}

$missing = $confirmed | Where-Object { $_ -notin $all } |
           ForEach-Object { [pscustomobject]@{ Server = $_; Status = 'ConfirmedButNotInList'; Detail = 'On the confirmed list but missing from the main list' } }

$final = @($results) + @($missing)
$outDir = Split-Path $OutputPath
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
$final | Export-Csv $OutputPath -NoTypeInformation

$final | Group-Object Status | Select-Object Name, Count | Format-Table -AutoSize
Write-Host "Report: $OutputPath"
