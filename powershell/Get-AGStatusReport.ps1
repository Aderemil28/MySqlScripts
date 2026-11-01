<#
.SYNOPSIS
    Availability group (and distributed AG) status report: who is primary and secondary, commit and
    failover mode, and the sync state of every database on every replica.

.DESCRIPTION
    Queries each AG's current primary (it has the full view of its replicas), plus the DAG global
    primary for the distributed AG if one is given, and shows:
      Replicas   AG, replica, role, availability mode, failover mode, connected state, health
      Databases  AG, replica, database, sync state, health, log send / redo queue, last commit time
    Ends with an overall verdict: HEALTHY, or a list of exactly what is not.

    Healthy means:
      - every replica CONNECTED and HEALTHY
      - synchronous-commit replicas: every database SYNCHRONIZED
      - asynchronous-commit replicas (for example the DAG link): SYNCHRONIZING or SYNCHRONIZED

    Also saves an HTML copy to -ReportFolder. Invoke-AGPatching.ps1 and Invoke-SQLPatching.ps1 call
    this automatically at the end of every run when it sits in the same folder.

.PARAMETER AvailabilityGroups
    One hashtable per AG with its name and nodes, for example:
      @{ Name = 'AG1'; Nodes = 'SQLNODE01','SQLNODE02' }, @{ Name = 'AG2'; Nodes = 'SQLNODE03','SQLNODE04' }

.PARAMETER DagName
    Name of the distributed AG that links the AGs above. Leave empty if there is none.

.PARAMETER SqlPort
    TCP port the instances listen on. Connections go straight to tcp:<node>,<port>, so a
    non-default port never falls back to Named Pipes.

.PARAMETER ReportFolder
    Where the HTML copy is saved.

.PARAMETER NoHtml
    Console output only.

.EXAMPLE
    .\Get-AGStatusReport.ps1 -AvailabilityGroups @{ Name = 'AG1'; Nodes = 'SQLNODE01','SQLNODE02' }

.EXAMPLE
    $ags = @{ Name = 'AG1'; Nodes = 'SQLNODE01','SQLNODE02' }, @{ Name = 'AG2'; Nodes = 'SQLNODE03','SQLNODE04' }
    .\Get-AGStatusReport.ps1 -AvailabilityGroups $ags -DagName 'DAG1' -SqlPort 1555

.NOTES
    Read-only. Run from a management machine or any server that can reach every node.
    Needs VIEW SERVER STATE on every instance (sysadmin is simplest).
    Windows PowerShell 5.1 or PowerShell 7.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [hashtable[]]$AvailabilityGroups,
    [string]$DagName,
    [int]$SqlPort = 1433,
    [string]$ReportFolder = 'C:\Scripts\Logs_AGStatus',
    [switch]$NoHtml
)

$ErrorActionPreference = 'Stop'

function Invoke-StatusSql {
    param([string]$Server, [string]$Query)
    $conn = New-Object System.Data.SqlClient.SqlConnection "Server=tcp:$Server,$SqlPort;Database=master;Integrated Security=True;Connect Timeout=15;Application Name=AGStatusReport"
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $Query
        $cmd.CommandTimeout = 60
        $table = New-Object System.Data.DataTable
        $table.Load($cmd.ExecuteReader())
        $table.Rows
    }
    finally { $conn.Dispose() }
}

function Find-AGPrimary {
    param([string]$AG, [string[]]$Nodes)
    foreach ($n in $Nodes) {
        try {
            $r = @(Invoke-StatusSql $n "SELECT ars.role_desc FROM sys.dm_hadr_availability_replica_states ars JOIN sys.availability_groups ag ON ars.group_id = ag.group_id WHERE ag.name = N'$AG' AND ars.is_local = 1;")
            if ($r.Count -and $r[0].role_desc -eq 'PRIMARY') { return $n }
        } catch { }
    }
    $null
}

function Get-ReplicaQuery([string]$AG) {
@"
SELECT ag.name AS AGName, ar.replica_server_name AS Replica,
       ISNULL(ars.role_desc, 'UNKNOWN') AS Role,
       ar.availability_mode_desc AS AvailabilityMode, ar.failover_mode_desc AS FailoverMode,
       ISNULL(ars.connected_state_desc, 'UNKNOWN') AS Connected,
       ISNULL(ars.synchronization_health_desc, 'UNKNOWN') AS Health
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states ars ON ar.replica_id = ars.replica_id
WHERE ag.name = N'$AG'
ORDER BY CASE ars.role_desc WHEN 'PRIMARY' THEN 0 ELSE 1 END, ar.replica_server_name;
"@
}

function Get-DatabaseQuery([string]$AG) {
@"
SELECT ag.name AS AGName, ar.replica_server_name AS Replica,
       ISNULL(adc.database_name, DB_NAME(drs.database_id)) AS DatabaseName,
       ar.availability_mode_desc AS AvailabilityMode,
       drs.synchronization_state_desc AS SyncState, drs.synchronization_health_desc AS Health,
       ISNULL(drs.log_send_queue_size, 0) AS LogSendQueueKB, ISNULL(drs.redo_queue_size, 0) AS RedoQueueKB,
       drs.last_commit_time AS LastCommitTime
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar ON drs.replica_id = ar.replica_id
JOIN sys.availability_groups ag ON drs.group_id = ag.group_id
LEFT JOIN sys.availability_databases_cluster adc
       ON drs.group_id = adc.group_id AND drs.group_database_id = adc.group_database_id
WHERE ag.name = N'$AG'
ORDER BY DatabaseName, ar.replica_server_name;
"@
}

$replicaCols  = 'AGName', 'Replica', 'Role', 'AvailabilityMode', 'FailoverMode', 'Connected', 'Health'
$databaseCols = 'AGName', 'Replica', 'DatabaseName', 'AvailabilityMode', 'SyncState', 'Health', 'LogSendQueueKB', 'RedoQueueKB', 'LastCommitTime'

$replicas  = New-Object System.Collections.Generic.List[object]
$databases = New-Object System.Collections.Generic.List[object]
$problems  = New-Object System.Collections.Generic.List[string]
$globalPrimary = $null

# ---- Local AGs (queried on each AG's primary) ----
foreach ($g in $AvailabilityGroups) {
    $p = Find-AGPrimary $g.Name $g.Nodes
    if (-not $p) { $problems.Add("$($g.Name): no PRIMARY found on $($g.Nodes -join ', ')"); continue }

    Invoke-StatusSql $p (Get-ReplicaQuery $g.Name)  | Select-Object $replicaCols  | ForEach-Object { $replicas.Add($_) }
    Invoke-StatusSql $p (Get-DatabaseQuery $g.Name) | Select-Object $databaseCols | ForEach-Object { $databases.Add($_) }

    if ($DagName) {
        $dr = @(Invoke-StatusSql $p "SELECT ars.role_desc FROM sys.dm_hadr_availability_replica_states ars JOIN sys.availability_replicas ar ON ars.replica_id = ar.replica_id JOIN sys.availability_groups ag ON ar.group_id = ag.group_id WHERE ag.name = N'$DagName' AND ar.replica_server_name = N'$($g.Name)';")
        if ($dr.Count -and $dr[0].role_desc -eq 'PRIMARY') { $globalPrimary = $p }
    }
}

# ---- DAG (queried on the global primary) ----
if ($DagName) {
    if ($globalPrimary) {
        Invoke-StatusSql $globalPrimary (Get-ReplicaQuery $DagName)  | Select-Object $replicaCols  | ForEach-Object { $replicas.Add($_) }
        Invoke-StatusSql $globalPrimary (Get-DatabaseQuery $DagName) | Select-Object $databaseCols | ForEach-Object { $databases.Add($_) }
    }
    else {
        $problems.Add("${DagName}: could not find the global primary")
    }
}

# ---- Health evaluation ----
foreach ($r in $replicas) {
    if ($r.Connected -ne 'CONNECTED' -or $r.Health -ne 'HEALTHY') {
        $problems.Add("$($r.AGName) / $($r.Replica): $($r.Connected), $($r.Health)")
    }
}
foreach ($d in $databases) {
    $okStates = if ($d.AvailabilityMode -eq 'SYNCHRONOUS_COMMIT') { @('SYNCHRONIZED') } else { @('SYNCHRONIZING', 'SYNCHRONIZED') }
    if ($d.SyncState -notin $okStates -or $d.Health -ne 'HEALTHY') {
        $problems.Add("$($d.AGName) / $($d.Replica) / $($d.DatabaseName): $($d.SyncState), $($d.Health)")
    }
}

# ---- Output ----
$stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
Write-Host "`n===== AG status report  ($stamp) =====" -ForegroundColor Cyan
Write-Host "`nReplicas" -ForegroundColor Cyan
$replicas | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
Write-Host "Databases" -ForegroundColor Cyan
$databases | Format-Table -AutoSize | Out-String -Width 250 | Write-Host

if ($problems.Count -eq 0) {
    Write-Host "Overall: HEALTHY. All replicas connected, all databases in the expected sync state." -ForegroundColor Green
}
else {
    Write-Host "Overall: ISSUES FOUND" -ForegroundColor Red
    $problems | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
}

if (-not $NoHtml) {
    New-Item -Path $ReportFolder -ItemType Directory -Force | Out-Null
    $htmlPath = Join-Path $ReportFolder ("AG-Status_{0}.html" -f (Get-Date -Format 'yyyyMMdd_HHmm'))
    $verdict = if ($problems.Count -eq 0) { "<p class='ok'>Overall: HEALTHY</p>" }
               else { "<p class='bad'>Overall: ISSUES FOUND</p><ul>" + (($problems | ForEach-Object { "<li>$_</li>" }) -join '') + "</ul>" }
    $style = @'
<style>
body { font-family: Segoe UI, Arial, sans-serif; font-size: 13px; margin: 20px; }
h1 { font-size: 18px; } h2 { font-size: 15px; margin-top: 24px; }
table { border-collapse: collapse; } th, td { border: 1px solid #ccc; padding: 4px 8px; text-align: left; }
th { background: #f0f0f0; } .ok { color: #1a7f37; font-weight: bold; } .bad { color: #c62828; font-weight: bold; }
</style>
'@
    $body = "<h1>AG status report - $stamp</h1>$verdict" +
            "<h2>Replicas</h2>"  + ($replicas  | ConvertTo-Html -Fragment | Out-String) +
            "<h2>Databases</h2>" + ($databases | ConvertTo-Html -Fragment | Out-String)
    ConvertTo-Html -Head $style -Body $body -Title 'AG status report' | Set-Content -Path $htmlPath -Encoding UTF8
    Write-Host "`nHTML report: $htmlPath" -ForegroundColor Cyan
}
