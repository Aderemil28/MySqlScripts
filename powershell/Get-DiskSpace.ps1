<#
.SYNOPSIS
    Size, free space and % free for every fixed drive and mount point on one or
    more servers, in GB, with a threshold flag.

.DESCRIPTION
    Uses Win32_Volume over CIM, which includes mount points (common for SQL data
    and log volumes) and drives that hold no database files, unlike
    sys.dm_os_volume_stats. Tries WinRM first and falls back to DCOM.

.PARAMETER ComputerName
    Servers to check. Defaults to the local machine.

.PARAMETER ServerListPath
    Text file with one server per line.

.PARAMETER MinFreePct
    Volumes below this % free are flagged LOW.

.EXAMPLE
    .\Get-DiskSpace.ps1
    .\Get-DiskSpace.ps1 -ServerListPath .\sqlservers.txt -MinFreePct 15 | Export-Csv C:\Temp\disk.csv -NoTypeInformation

.NOTES
    Read-only.
#>
[CmdletBinding()]
param(
    [string[]]$ComputerName = $env:COMPUTERNAME,
    [string]$ServerListPath,
    [decimal]$MinFreePct = 15
)

if ($ServerListPath) { $ComputerName = Get-Content $ServerListPath | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() } }

foreach ($s in ($ComputerName | Sort-Object -Unique)) {
    $session = $null
    foreach ($p in 'Wsman', 'Dcom') {
        try {
            $session = New-CimSession -ComputerName $s -SessionOption (New-CimSessionOption -Protocol $p) -OperationTimeoutSec 30 -ErrorAction Stop
            break
        } catch { Write-Verbose "$s : $p failed, trying next protocol" }
    }
    if (-not $session) {
        [pscustomobject]@{ Server = $s; Volume = ''; Label = ''; TotalGB = $null; FreeGB = $null; FreePct = $null; Status = 'Unreachable' }
        continue
    }

    try {
        Get-CimInstance -CimSession $session -ClassName Win32_Volume -Filter 'DriveType = 3' |
            Where-Object { $_.Capacity -gt 0 -and $_.Name -notlike '\\?\Volume*' } |
            Sort-Object Name |
            ForEach-Object {
                $freePct = [math]::Round($_.FreeSpace * 100 / $_.Capacity, 2)
                [pscustomobject]@{
                    Server  = $s
                    Volume  = $_.Name
                    Label   = $_.Label
                    TotalGB = [math]::Round($_.Capacity / 1GB, 1)
                    FreeGB  = [math]::Round($_.FreeSpace / 1GB, 1)
                    FreePct = $freePct
                    Status  = if ($freePct -lt $MinFreePct) { 'LOW' } else { 'OK' }
                }
            }
    } finally {
        Remove-CimSession $session
    }
}
