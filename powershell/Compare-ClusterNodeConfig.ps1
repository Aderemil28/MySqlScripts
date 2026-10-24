<#
.SYNOPSIS
    Compares the *_config.csv files produced by Get-ClusterNodeConfig.ps1 across
    any number of nodes and writes a side-by-side report plus a differences-only report.

.DESCRIPTION
    Picks up every file matching *_config.csv in -Folder (other files are ignored),
    builds one row per Category/Setting with one column per node, and writes:
      Compare.csv        every setting
      Compare_Diffs.csv  only settings whose values differ, with identity noise
                         (addresses, NIC names, boot times) filtered out

    NIC rows are matched by setting name across all adapters, so nodes with
    differently named adapters still line up.

.PARAMETER Folder
    Folder holding the <node>_config.csv files.

.EXAMPLE
    .\Compare-ClusterNodeConfig.ps1 -Folder C:\Temp\ClusterCompare

.NOTES
    Read-only. Copy all node CSVs into the folder before running; zero files
    found usually means they are still on the nodes.
#>
[CmdletBinding()]
param(
    [string]$Folder = 'C:\Temp'
)

$files = Get-ChildItem -Path $Folder -Filter '*_config.csv' -File
if (-not $files) {
    Write-Warning "No *_config.csv files found in $Folder."
    return
}
Write-Host "Comparing $($files.Count) node(s): $(($files | ForEach-Object { $_.BaseName -replace '_config$','' }) -join ', ')"

$nodes = @{}
foreach ($f in $files) {
    $node = $f.BaseName -replace '_config$', ''
    $nodes[$node] = Import-Csv $f.FullName
}

# Key: Category | Item | Setting. For NICs use Category | Setting so adapters with different names still match.
function Get-Key($row) {
    if ($row.Category -eq 'NIC') { "NIC|*|$($row.Setting)" } else { "$($row.Category)|$($row.Item)|$($row.Setting)" }
}

$allKeys = $nodes.Values | ForEach-Object { $_ } | ForEach-Object { Get-Key $_ } | Sort-Object -Unique
$nodeNames = $nodes.Keys | Sort-Object

$report = foreach ($k in $allKeys) {
    $parts = $k -split '\|', 3
    $obj = [ordered]@{ Category = $parts[0]; Item = $parts[1]; Setting = $parts[2] }
    $values = @()
    foreach ($n in $nodeNames) {
        $v = ($nodes[$n] | Where-Object { (Get-Key $_) -eq $k } | Select-Object -ExpandProperty Value -Unique) -join '; '
        $obj[$n] = $v
        $values += $v
    }
    $obj['Different'] = (($values | Sort-Object -Unique).Count -gt 1)
    [pscustomobject]$obj
}

$noise = 'Address|LastBootUp|InterfaceDescription|DnsName|MAC|Network Address|OwnerGroup|State'

$report | Export-Csv (Join-Path $Folder 'Compare.csv') -NoTypeInformation
$diffs = $report | Where-Object { $_.Different -and $_.Setting -notmatch $noise }
$diffs | Export-Csv (Join-Path $Folder 'Compare_Diffs.csv') -NoTypeInformation

Write-Host "Settings compared : $(@($report).Count)"
Write-Host "Differences       : $(@($diffs).Count) (see Compare_Diffs.csv)"
$diffs | Select-Object -First 25 | Format-Table -AutoSize
