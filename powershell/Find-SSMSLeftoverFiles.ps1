<#
.SYNOPSIS
    Read-only scan for files left behind by an older SSMS version after an upgrade,
    for example to close a vulnerability finding against the old build.

.DESCRIPTION
    Looks in the SSMS install folders and the Visual Studio package cache for:
      - binaries whose ProductVersion starts with the old version prefix
      - curl / libcurl DLLs (a common source of SSMS-related findings)
      - old install folders
    Files written at or after -UpgradeTime are marked as "Upgraded" because they
    came from the new install, not the old one. This avoids false positives from
    unrelated components that share a similar version number.

.PARAMETER OldVersionPrefix
    Version prefix of the old build, for example '22.1.'.

.PARAMETER UpgradeTime
    When the upgrade finished. Files written after this are treated as new.

.PARAMETER OutputPath
    CSV report path.

.EXAMPLE
    .\Find-SSMSLeftoverFiles.ps1 -OldVersionPrefix '22.1.' -UpgradeTime '2026-10-20 14:30'

.NOTES
    Read-only. Run elevated so protected folders can be read.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OldVersionPrefix,
    [datetime]$UpgradeTime = (Get-Date).AddYears(-10),
    [string]$OutputPath = "C:\Temp\SSMS_leftovers_$($env:COMPUTERNAME).csv"
)

$roots = @(
    "${env:ProgramFiles}\Microsoft SQL Server Management Studio*",
    "${env:ProgramFiles(x86)}\Microsoft SQL Server Management Studio*",
    "${env:ProgramData}\Microsoft\VisualStudio\Packages"
) | Where-Object { Test-Path $_ }

if (-not $roots) {
    Write-Warning 'No SSMS install or package cache folders found.'
    return
}

$results = foreach ($root in $roots) {
    Get-ChildItem -Path $root -Recurse -File -Include *.dll, *.exe -ErrorAction SilentlyContinue |
        ForEach-Object {
            $ver   = $_.VersionInfo.ProductVersion
            $isOld = $ver -and $ver.StartsWith($OldVersionPrefix)
            $isCurl = $_.Name -match 'curl'
            if ($isOld -or $isCurl) {
                [pscustomobject]@{
                    File           = $_.FullName
                    ProductVersion = $ver
                    LastWriteTime  = $_.LastWriteTime
                    Reason         = if ($isCurl) { 'curl binary' } else { 'Old version prefix' }
                    Status         = if ($_.LastWriteTime -ge $UpgradeTime) { 'Upgraded (written after upgrade)' } else { 'Possible leftover' }
                }
            }
        }
}

# Old install folders, assigned to a variable first so it can be piped (piping foreach directly is a parse error)
$folders = foreach ($root in $roots) {
    Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "*$OldVersionPrefix*" } |
        Select-Object FullName, LastWriteTime
}

$outDir = Split-Path $OutputPath
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

if ($results) {
    $results | Sort-Object Status, File | Export-Csv -Path $OutputPath -NoTypeInformation
    $results | Group-Object Status | Select-Object Name, Count | Format-Table -AutoSize
    Write-Host "Report: $OutputPath"
} else {
    Write-Host 'Clean: no old-version or curl binaries found.' -ForegroundColor Green
}

if ($folders) {
    Write-Host "`nFolders matching the old version:" -ForegroundColor Yellow
    $folders | Format-Table -AutoSize
}
