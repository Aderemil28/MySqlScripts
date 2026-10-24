<#
.SYNOPSIS
    Finds which Python runtimes exist on a server and whether any running
    process has them loaded. Built for vulnerability findings such as
    "Python 3.x detected / end of life".

.DESCRIPTION
    Local mode (no -ComputerName):
      1. Running processes that have a pythonXY.dll loaded (in use right now)
      2. python.exe and python3*.dll copies on fixed drives, with file version
         and the folder they live in (shows which product bundled them)
    Sweep mode (-ComputerName or -ServerListPath):
      searches the usual install roots on each server through the admin share
      (\\server\c$), which needs no WinRM.

.PARAMETER VersionLike
    File name filter for the DLL, for example 'python310*.dll' for 3.10.

.PARAMETER ComputerName
    One or more servers to sweep.

.PARAMETER ServerListPath
    Text file with one server per line to sweep.

.EXAMPLE
    .\Find-PythonRuntime.ps1                                   # local, full detail
    .\Find-PythonRuntime.ps1 -VersionLike 'python310*.dll' -ServerListPath .\sqlservers.txt

.NOTES
    Run elevated. Read-only. A full local drive search can take a few minutes.
    SQL Server's own Python use is covered by tsql/monitoring/python-r-external-scripts-check.sql.
#>
[CmdletBinding()]
param(
    [string]$VersionLike = 'python3*.dll',
    [string[]]$ComputerName,
    [string]$ServerListPath,
    [string]$OutputPath = 'C:\Temp\python_runtime_check.csv'
)

$sweepRoots = @('Program Files', 'Program Files (x86)', 'ProgramData')

if ($ServerListPath) { $ComputerName += Get-Content $ServerListPath | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() } }

if (-not $ComputerName) {
    # ---------- Local mode ----------
    Write-Host '1. Processes with a Python DLL loaded:' -ForegroundColor Cyan
    $inUse = foreach ($p in Get-Process) {
        try {
            foreach ($m in $p.Modules) {
                if ($m.ModuleName -like $VersionLike) {
                    [pscustomobject]@{ Process = $p.ProcessName; PID = $p.Id; Module = $m.ModuleName; Path = $m.FileName }
                }
            }
        } catch { Write-Verbose "Skipped $($p.ProcessName): $($_.Exception.Message)" }   # access denied on protected processes
    }
    if ($inUse) { $inUse | Format-Table -AutoSize } else { Write-Host '   None' -ForegroundColor Green }

    Write-Host '2. Python files on fixed drives:' -ForegroundColor Cyan
    $drives = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | Select-Object -ExpandProperty DeviceID
    $files = foreach ($d in $drives) {
        Get-ChildItem -Path "$d\" -Recurse -File -Include 'python.exe', $VersionLike -ErrorAction SilentlyContinue |
            Select-Object @{ n = 'Server'; e = { $env:COMPUTERNAME } }, FullName,
                          @{ n = 'FileVersion'; e = { $_.VersionInfo.FileVersion } }, LastWriteTime
    }
    $files | Format-Table -AutoSize
    $result = $files
} else {
    # ---------- Sweep mode ----------
    $result = foreach ($s in ($ComputerName | Sort-Object -Unique)) {
        Write-Host "Checking $s ..."
        $share = "\\$s\c$"
        if (-not (Test-Path $share)) {
            [pscustomobject]@{ Server = $s; FullName = ''; FileVersion = ''; LastWriteTime = $null; Note = 'Admin share not reachable' }
            continue
        }
        $hits = foreach ($r in $sweepRoots) {
            $path = Join-Path $share $r
            if (Test-Path $path) {
                Get-ChildItem -Path $path -Recurse -File -Filter $VersionLike -ErrorAction SilentlyContinue
            }
        }
        if ($hits) {
            $hits | ForEach-Object {
                [pscustomobject]@{ Server = $s; FullName = $_.FullName; FileVersion = $_.VersionInfo.FileVersion; LastWriteTime = $_.LastWriteTime; Note = '' }
            }
        } else {
            [pscustomobject]@{ Server = $s; FullName = ''; FileVersion = ''; LastWriteTime = $null; Note = 'Not found' }
        }
    }
    $result | Format-Table -AutoSize
}

$outDir = Split-Path $OutputPath
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
$result | Export-Csv $OutputPath -NoTypeInformation
Write-Host "Report: $OutputPath"
