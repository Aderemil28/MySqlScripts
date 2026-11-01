<#
.SYNOPSIS
    Downloads the latest SSMS 22 from Microsoft and silently updates it on one or more servers.

.DESCRIPTION
    1. Downloads the official SSMS 22 bootstrapper once. The link always points to the latest release.
    2. Copies it to each server over PowerShell remoting.
    3. Records the current SSMS version, runs a silent update, records the new version.
    4. Prints a before/after summary.

    Without -Execute it only reports the SSMS 22 version and install path on each server.
    Servers already on the newest build finish quickly with nothing changed (Before and After match).

    Pair it with Register-SSMSAutoUpdate.ps1 to run it on a schedule.

.PARAMETER ComputerName
    Servers to check or update. Defaults to the local machine.

.PARAMETER Execute
    Download the bootstrapper and update SSMS. Without it the script only reports.

.PARAMETER InstallIfMissing
    With -Execute, do a fresh install on servers where SSMS 22 is not installed.

.PARAMETER Force
    Close SSMS if it is open on a server. Without it, the update fails on servers where SSMS is running.

.PARAMETER DownloadFolder
    Where the bootstrapper is saved locally and on each server.

.EXAMPLE
    .\Update-SSMS.ps1 -ComputerName SQLNODE01, SQLNODE02

.EXAMPLE
    .\Update-SSMS.ps1 -ComputerName SQLNODE01, SQLNODE02, SQLNODE03, SQLNODE04 -Execute -Force

.NOTES
    Run elevated, as an account that is local admin on the servers. Servers need PowerShell remoting
    (WinRM) and internet access, because the bootstrapper downloads the actual payload from Microsoft.
    Exit codes: 0 success, 3010 success with reboot required, 1001 SSMS was open (use -Force).
    Installer logs are dd_*.log in %TEMP% on the server.
    Windows PowerShell 5.1.
#>
[CmdletBinding()]
param(
    [string[]]$ComputerName = $env:COMPUTERNAME,
    [switch]$Execute,
    [switch]$InstallIfMissing,
    [switch]$Force,
    [string]$DownloadFolder = 'C:\Temp\SSMS'
)

$ErrorActionPreference = 'Stop'
$downloadUrl = 'https://aka.ms/ssms/22/release/vs_SSMS.exe'
$localFile   = Join-Path $DownloadFolder 'vs_SSMS.exe'

# Runs on each server. Without a bootstrapper path it only reports.
$updateBlock = {
    param($BootstrapperPath, $InstallIfMissing, $Force)

    function Get-SsmsInfo {
        $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
        if (-not (Test-Path $vswhere)) { return $null }
        $json = & $vswhere -all -prerelease -products * -format json 2>$null
        if (-not $json) { return $null }
        ($json | ConvertFrom-Json) |
            Where-Object { $_.displayName -like '*Management Studio 22*' } |
            Select-Object -First 1 @{n='Version';e={$_.catalog.productDisplayVersion}},
                                   @{n='InstallPath';e={$_.installationPath}}
    }

    $before = Get-SsmsInfo

    if (-not $BootstrapperPath) {
        return [pscustomobject]@{
            Computer = $env:COMPUTERNAME; Action = 'Report'
            Before = if ($before) { $before.Version } else { 'Not installed' }
            After = $null; ExitCode = $null
            Result = if ($before) { $before.InstallPath } else { 'SSMS 22 not found' }
        }
    }

    $installArgs = @()
    if ($before) {
        $action = 'Update'
        $installArgs = @('update', '--installPath', "`"$($before.InstallPath)`"", '--quiet', '--norestart', '--wait')
    }
    elseif ($InstallIfMissing) {
        $action = 'Install'
        $installArgs = @('--quiet', '--norestart', '--wait')
    }
    else {
        return [pscustomobject]@{
            Computer = $env:COMPUTERNAME; Action = 'Skipped'; Before = 'Not installed'
            After = $null; ExitCode = $null; Result = 'SSMS 22 not found (use -InstallIfMissing)'
        }
    }

    if ($Force) { $installArgs += '--force' }

    $proc  = Start-Process -FilePath $BootstrapperPath -ArgumentList $installArgs -Wait -PassThru -NoNewWindow
    $after = Get-SsmsInfo

    $result = switch ($proc.ExitCode) {
        0       { 'Success' }
        3010    { 'Success - reboot required' }
        1001    { 'Failed - SSMS is open (rerun with -Force)' }
        default { "Failed - see logs in $env:TEMP (dd_*.log)" }
    }

    [pscustomobject]@{
        Computer = $env:COMPUTERNAME
        Action   = $action
        Before   = if ($before) { $before.Version } else { 'Not installed' }
        After    = if ($after)  { $after.Version }  else { $null }
        ExitCode = $proc.ExitCode
        Result   = $result
    }
}

# ---- 1. Download the bootstrapper once (only when updating) ----
if ($Execute) {
    New-Item -Path $DownloadFolder -ItemType Directory -Force | Out-Null
    Write-Host "Downloading latest SSMS 22 bootstrapper from Microsoft..." -ForegroundColor Cyan
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $downloadUrl -OutFile $localFile -UseBasicParsing
    Write-Host "Saved to $localFile" -ForegroundColor Green
}
else {
    Write-Host "Report only. Add -Execute to update SSMS." -ForegroundColor Yellow
}

# ---- 2. Run against each server ----
$summary = foreach ($computer in $ComputerName) {
    Write-Host "`n[$computer] Starting..." -ForegroundColor Cyan
    try {
        $isLocal = $computer -in @($env:COMPUTERNAME, 'localhost', '.')
        if (-not $Execute) {
            if ($isLocal) { & $updateBlock $null $false $false }
            else { Invoke-Command -ComputerName $computer -ScriptBlock $updateBlock -ArgumentList $null, $false, $false }
        }
        elseif ($isLocal) {
            & $updateBlock $localFile $InstallIfMissing.IsPresent $Force.IsPresent
        }
        else {
            $remoteFile = Join-Path $DownloadFolder 'vs_SSMS.exe'
            $session = New-PSSession -ComputerName $computer
            try {
                Invoke-Command -Session $session -ArgumentList $DownloadFolder -ScriptBlock {
                    param($d) New-Item -Path $d -ItemType Directory -Force | Out-Null
                }
                Copy-Item -Path $localFile -Destination $remoteFile -ToSession $session -Force
                Invoke-Command -Session $session -ScriptBlock $updateBlock `
                    -ArgumentList $remoteFile, $InstallIfMissing.IsPresent, $Force.IsPresent
            }
            finally { Remove-PSSession $session }
        }
    }
    catch {
        [pscustomobject]@{
            Computer = $computer; Action = 'Error'; Before = $null
            After = $null; ExitCode = $null; Result = $_.Exception.Message
        }
    }
}

# ---- 3. Summary ----
Write-Host "`n===== SSMS summary =====" -ForegroundColor Cyan
$summary | Select-Object Computer, Action, Before, After, ExitCode, Result | Format-Table -AutoSize
