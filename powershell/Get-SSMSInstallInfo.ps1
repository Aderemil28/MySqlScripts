<#
.SYNOPSIS
    Reports the installed SQL Server Management Studio version(s) and, optionally,
    upgrades SSMS 21+ in place through the Visual Studio Installer.

.DESCRIPTION
    SSMS 21 and later install through the Visual Studio Installer, so they do not
    show up the way SSMS 18/19/20 did. This script:
      - finds vswhere.exe and lists every SSMS 21+ instance (version, path, channel)
      - checks the registry for legacy SSMS 18/19/20 installs
      - prints the upgrade command, and runs it when -Upgrade is used

.PARAMETER Upgrade
    Runs the VS Installer update for each SSMS 21+ instance found (quiet, no restart).
    Close SSMS first.

.EXAMPLE
    .\Get-SSMSInstallInfo.ps1
    .\Get-SSMSInstallInfo.ps1 -Upgrade

.NOTES
    Run in an elevated PowerShell session. Windows PowerShell 5.1 or PowerShell 7.
    If ISE was reopened, re-run:
        Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
    and cd back to the script folder.
#>
[CmdletBinding()]
param(
    [switch]$Upgrade
)

$ErrorActionPreference = 'Stop'

# --- SSMS 21+ (Visual Studio Installer based) ---
$installerDir = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer'
$vswhere      = Join-Path $installerDir 'vswhere.exe'
$setup        = Join-Path $installerDir 'setup.exe'

$instances = @()
if (Test-Path $vswhere) {
    $json = & $vswhere -all -prerelease -products * -format json
    if ($json) {
        $instances = ($json | ConvertFrom-Json) |
            Where-Object { $_.displayName -like '*Management Studio*' }
    }
}

if ($instances) {
    Write-Host "`nSSMS 21+ instances:" -ForegroundColor Cyan
    $instances | Select-Object displayName,
        @{n='Version'; e={$_.catalog.productDisplayVersion}},
        installationVersion, installationPath,
        @{n='Channel'; e={$_.channelId}} | Format-List
} else {
    Write-Host "`nNo SSMS 21+ instance found through vswhere." -ForegroundColor Yellow
}

# --- Legacy SSMS (18/19/20) from the uninstall registry keys ---
$uninstallKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
$legacy = Get-ItemProperty $uninstallKeys -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -like 'SQL Server Management Studio*' -or
                   $_.DisplayName -like 'Microsoft SQL Server Management Studio*' } |
    Select-Object DisplayName, DisplayVersion, InstallLocation, InstallDate

if ($legacy) {
    Write-Host "Legacy SSMS installs (registry):" -ForegroundColor Cyan
    $legacy | Format-Table -AutoSize
}

# --- Upgrade command ---
foreach ($i in $instances) {
    $cmd = "`"$setup`" update --installPath `"$($i.installationPath)`" --quiet --norestart"
    Write-Host "Upgrade command for $($i.installationPath):" -ForegroundColor Cyan
    Write-Host "  $cmd"

    if ($Upgrade) {
        if (Get-Process -Name Ssms -ErrorAction SilentlyContinue) {
            Write-Warning 'SSMS is running. Close it and run again.'
            continue
        }
        Write-Host 'Upgrading...' -ForegroundColor Green
        $p = Start-Process -FilePath $setup `
                -ArgumentList @('update', '--installPath', "`"$($i.installationPath)`"", '--quiet', '--norestart') `
                -Wait -PassThru
        # 0 = success, 3010 = success but a reboot is required
        Write-Host "Exit code: $($p.ExitCode)"
    }
}

if ($Upgrade -and $instances) {
    Write-Host "`nVersion after upgrade:" -ForegroundColor Cyan
    ((& $vswhere -all -prerelease -products * -format json) | ConvertFrom-Json) |
        Where-Object { $_.displayName -like '*Management Studio*' } |
        Select-Object displayName, @{n='Version'; e={$_.catalog.productDisplayVersion}} | Format-Table -AutoSize
}
