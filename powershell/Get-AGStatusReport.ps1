<#
.SYNOPSIS
    Availability group (and distributed AG) status report, with automatic root-cause diagnostics
    when anything is unhealthy.

.DESCRIPTION
    Status (always):
      Replicas   AG, replica, role, availability mode, failover mode, connected state, health
      Databases  AG, replica, database, sync state, health, log send / redo queue, last commit time
      Verdict    HEALTHY, or a list of exactly what is not

    Diagnostics (automatically when the verdict is not HEALTHY, or always with -Diagnose).
    Every node is queried directly, so a node whose view differs from the primary's still shows up:
      Cluster    node state (Up / Down / Paused) and status (Normal / Isolated / Quarantined),
                 quorum, the AG cluster resource state and owner, failover clustering events (24h)
      Replicas   role (including RESOLVING), operational state, recovery health, and the last
                 connection error each replica recorded talking to its partners
      Databases  database state (ONLINE / RECOVERING / ...), sync state, suspended data movement
                 and the reason, secondary lag
      Endpoints  mirroring endpoint state and port on each node
      Failover   whether each AG's primary is still the first node listed (the preferred primary),
                 and the role-change messages from the SQL Server error log with their reason
      Error log  Always On, lease, quorum and endpoint messages from the last 24 hours
    Then a "Likely causes" list: each finding in plain English with the fix to try first.

    Healthy means:
      - every replica CONNECTED and HEALTHY
      - synchronous-commit replicas: every database SYNCHRONIZED
      - asynchronous-commit replicas (for example the DAG link): SYNCHRONIZING or SYNCHRONIZED

    Also saves an HTML copy to -ReportFolder. Invoke-AGPatching.ps1 and Invoke-SQLPatching.ps1 call
    this automatically at the end of every run when it sits in the same folder.

.PARAMETER AvailabilityGroups
    One hashtable per AG with its name and nodes. List the preferred primary first, for example:
      @{ Name = 'AG1'; Nodes = 'SQLNODE01','SQLNODE02' }, @{ Name = 'AG2'; Nodes = 'SQLNODE03','SQLNODE04' }
    If omitted, read from -ConfigPath.

.PARAMETER DagName
    Name of the distributed AG that links the AGs above. Leave empty if there is none.

.PARAMETER SqlPort
    TCP port the instances listen on. Connections go straight to tcp:<node>,<port>, so a
    non-default port never falls back to Named Pipes.

.PARAMETER ConfigPath
    A .psd1 file holding AvailabilityGroups, DagName and SqlPort, so the script runs with no
    parameters (and the patching scripts can call it). Default: ag-config.psd1 next to this script.
    See ag-config.example.psd1. Parameters passed on the command line win over the file.

.PARAMETER Diagnose
    Run the diagnostics even when everything is healthy.

.PARAMETER ErrorLogHours
    How far back to read the SQL Server error log and cluster events.

.PARAMETER ReportFolder
    Where the HTML copy is saved.

.PARAMETER NoHtml
    Console output only.

.EXAMPLE
    .\Get-AGStatusReport.ps1          # uses ag-config.psd1 next to the script

.EXAMPLE
    $ags = @{ Name = 'AG1'; Nodes = 'SQLNODE01','SQLNODE02' }, @{ Name = 'AG2'; Nodes = 'SQLNODE03','SQLNODE04' }
    .\Get-AGStatusReport.ps1 -AvailabilityGroups $ags -DagName 'DAG1' -SqlPort 1555 -Diagnose

.NOTES
    Read-only. Run from a management machine or any server that can reach every node.
    Needs VIEW SERVER STATE on every instance (sysadmin is simplest). The cluster checks use
    PowerShell remoting to one node per AG and need local admin there; if remoting fails the
    report still runs and says the cluster could not be checked.
    Windows PowerShell 5.1.
#>
[CmdletBinding()]
param(
    [hashtable[]]$AvailabilityGroups,
    [string]$DagName,
    [int]$SqlPort = 1433,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'ag-config.psd1'),
    [switch]$Diagnose,
    [int]$ErrorLogHours = 24,
    [string]$ReportFolder = 'C:\Scripts\Logs_AGStatus',
    [switch]$NoHtml
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- configuration

if (-not $AvailabilityGroups) {
    if (-not (Test-Path $ConfigPath)) {
        throw "No -AvailabilityGroups given and no config file at $ConfigPath. Pass -AvailabilityGroups or create the file (see ag-config.example.psd1)."
    }
    $cfg = Import-PowerShellDataFile -Path $ConfigPath
    $AvailabilityGroups = $cfg.AvailabilityGroups
    if (-not $PSBoundParameters.ContainsKey('DagName') -and $cfg.DagName) { $DagName = $cfg.DagName }
    if (-not $PSBoundParameters.ContainsKey('SqlPort') -and $cfg.SqlPort) { $SqlPort = [int]$cfg.SqlPort }
}

# ---------------------------------------------------------------- helpers

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

# ---------------------------------------------------------------- status

$replicaCols  = 'AGName', 'Replica', 'Role', 'AvailabilityMode', 'FailoverMode', 'Connected', 'Health'
$databaseCols = 'AGName', 'Replica', 'DatabaseName', 'AvailabilityMode', 'SyncState', 'Health', 'LogSendQueueKB', 'RedoQueueKB', 'LastCommitTime'

$replicas  = New-Object System.Collections.Generic.List[object]
$databases = New-Object System.Collections.Generic.List[object]
$problems  = New-Object System.Collections.Generic.List[string]
$globalPrimary = $null
$primaries = @{}

foreach ($g in $AvailabilityGroups) {
    $p = Find-AGPrimary $g.Name $g.Nodes
    $primaries[$g.Name] = $p
    if (-not $p) { $problems.Add("$($g.Name): no PRIMARY found on $($g.Nodes -join ', ')"); continue }

    Invoke-StatusSql $p (Get-ReplicaQuery $g.Name)  | Select-Object $replicaCols  | ForEach-Object { $replicas.Add($_) }
    Invoke-StatusSql $p (Get-DatabaseQuery $g.Name) | Select-Object $databaseCols | ForEach-Object { $databases.Add($_) }

    if ($DagName) {
        $dr = @(Invoke-StatusSql $p "SELECT ars.role_desc FROM sys.dm_hadr_availability_replica_states ars JOIN sys.availability_replicas ar ON ars.replica_id = ar.replica_id JOIN sys.availability_groups ag ON ar.group_id = ag.group_id WHERE ag.name = N'$DagName' AND ar.replica_server_name = N'$($g.Name)';")
        if ($dr.Count -and $dr[0].role_desc -eq 'PRIMARY') { $globalPrimary = $p }
    }
}

if ($DagName) {
    if ($globalPrimary) {
        Invoke-StatusSql $globalPrimary (Get-ReplicaQuery $DagName)  | Select-Object $replicaCols  | ForEach-Object { $replicas.Add($_) }
        Invoke-StatusSql $globalPrimary (Get-DatabaseQuery $DagName) | Select-Object $databaseCols | ForEach-Object { $databases.Add($_) }
    }
    else { $problems.Add("${DagName}: could not find the global primary") }
}

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

# ---------------------------------------------------------------- diagnostics

$diag = [ordered]@{
    ClusterNodes = New-Object System.Collections.Generic.List[object]
    AGResources  = New-Object System.Collections.Generic.List[object]
    Quorum       = New-Object System.Collections.Generic.List[object]
    ClusterEvents= New-Object System.Collections.Generic.List[object]
    NodeReplicas = New-Object System.Collections.Generic.List[object]
    NodeDatabases= New-Object System.Collections.Generic.List[object]
    Endpoints    = New-Object System.Collections.Generic.List[object]
    ErrorLog     = New-Object System.Collections.Generic.List[object]
}
$causes = New-Object System.Collections.Generic.List[object]
function Add-Cause([string]$Where, [string]$Finding, [string]$Fix) {
    $causes.Add([pscustomobject]@{ Where = $Where; Finding = $Finding; TryFirst = $Fix })
}

$runDiag = $Diagnose -or ($problems.Count -gt 0)

if ($runDiag) {
    $agNames  = ($AvailabilityGroups | ForEach-Object { "N'$($_.Name)'" }) -join ','
    if ($DagName) { $agNames += ",N'$DagName'" }
    $allNodes = @($AvailabilityGroups | ForEach-Object { $_.Nodes })

    $qNodeReplicas = @"
SELECT ag.name AS AGName, ar.replica_server_name AS Replica, ars.is_local AS IsLocal,
       ISNULL(ars.role_desc, 'UNKNOWN') AS Role, ISNULL(ars.operational_state_desc, '') AS OperationalState,
       ISNULL(ars.recovery_health_desc, '') AS RecoveryHealth, ISNULL(ars.connected_state_desc, '') AS Connected,
       ISNULL(ars.synchronization_health_desc, '') AS Health,
       ars.last_connect_error_number AS LastErrNo, ars.last_connect_error_description AS LastErrText,
       ars.last_connect_error_timestamp AS LastErrTime
FROM sys.dm_hadr_availability_replica_states ars
JOIN sys.availability_replicas ar ON ars.replica_id = ar.replica_id
JOIN sys.availability_groups ag ON ar.group_id = ag.group_id
WHERE ag.name IN ($agNames);
"@
    $qNodeDatabases = @"
SELECT ag.name AS AGName, DB_NAME(drs.database_id) AS DatabaseName, d.state_desc AS DatabaseState,
       drs.synchronization_state_desc AS SyncState, drs.synchronization_health_desc AS Health,
       drs.is_suspended AS IsSuspended, ISNULL(drs.suspend_reason_desc, '') AS SuspendReason,
       drs.secondary_lag_seconds AS LagSeconds, drs.last_hardened_time AS LastHardened
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_groups ag ON drs.group_id = ag.group_id
JOIN sys.databases d ON d.database_id = drs.database_id
WHERE drs.is_local = 1 AND ag.name IN ($agNames);
"@
    $qEndpoints = @"
SELECT e.name AS EndpointName, e.state_desc AS State, t.port AS Port
FROM sys.database_mirroring_endpoints e
LEFT JOIN sys.tcp_endpoints t ON e.endpoint_id = t.endpoint_id;
"@
    $qQuorum = "SELECT cluster_name AS ClusterName, quorum_type_desc AS QuorumType, quorum_state_desc AS QuorumState FROM sys.dm_hadr_cluster;"
    $qErrorLog = @"
SET NOCOUNT ON;
CREATE TABLE #el (LogDate datetime, ProcessInfo nvarchar(100), [Text] nvarchar(max));
INSERT #el EXEC master.dbo.xp_readerrorlog 0, 1;
SELECT TOP (20) LogDate, [Text]
FROM #el
WHERE LogDate >= DATEADD(HOUR, -$ErrorLogHours, GETDATE())
  AND (   [Text] LIKE '%changing roles%' OR [Text] LIKE '%availability group%' OR [Text] LIKE '%Always On%'
       OR [Text] LIKE '%lease%' OR [Text] LIKE '%quorum%' OR [Text] LIKE '%mirroring%' OR [Text] LIKE '%endpoint%'
       OR [Text] LIKE '%Error: 354%' OR [Text] LIKE '%Error: 1480%' OR [Text] LIKE '%Error: 1947%' OR [Text] LIKE '%Error: 4114%')
ORDER BY LogDate DESC;
DROP TABLE #el;
"@

    # ---- per node: SQL view ----
    $unreachable = @()
    foreach ($n in $allNodes) {
        try {
            Invoke-StatusSql $n $qNodeReplicas  | Select-Object @{n='Node';e={$n}}, AGName, Replica, IsLocal, Role, OperationalState, RecoveryHealth, Connected, Health, LastErrNo, LastErrText, LastErrTime | ForEach-Object { $diag.NodeReplicas.Add($_) }
            Invoke-StatusSql $n $qNodeDatabases | Select-Object @{n='Node';e={$n}}, AGName, DatabaseName, DatabaseState, SyncState, Health, IsSuspended, SuspendReason, LagSeconds, LastHardened | ForEach-Object { $diag.NodeDatabases.Add($_) }
            Invoke-StatusSql $n $qEndpoints     | Select-Object @{n='Node';e={$n}}, EndpointName, State, Port | ForEach-Object { $diag.Endpoints.Add($_) }
            Invoke-StatusSql $n $qQuorum        | Select-Object @{n='Node';e={$n}}, ClusterName, QuorumType, QuorumState | ForEach-Object { $diag.Quorum.Add($_) }
            Invoke-StatusSql $n $qErrorLog      | Select-Object @{n='Node';e={$n}}, LogDate, Text | ForEach-Object { $diag.ErrorLog.Add($_) }
        }
        catch {
            $unreachable += $n
            Add-Cause $n "Can't query SQL Server on ${n}: $($_.Exception.Message)" "Check the node is up, the SQL Server service is running, and port $SqlPort is reachable (Test-NetConnection $n -Port $SqlPort)."
        }
    }

    # ---- per AG: cluster view (each AG of a DAG is its own cluster) ----
    $clusterBlock = {
        param($hours)
        Import-Module FailoverClusters -ErrorAction Stop
        $cl = Get-Cluster
        [pscustomobject]@{
            Cluster   = $cl.Name
            Nodes     = @(Get-ClusterNode | ForEach-Object {
                            [pscustomobject]@{ Name = $_.Name; State = "$($_.State)"; Status = "$($_.StatusInformation)" } })
            Resources = @(Get-ClusterResource | Where-Object ResourceType -eq 'SQL Server Availability Group' | ForEach-Object {
                            [pscustomobject]@{ Name = $_.Name; State = "$($_.State)"; OwnerNode = "$($_.OwnerNode)" } })
            Events    = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-FailoverClustering'; StartTime = (Get-Date).AddHours(-$hours) } -MaxEvents 15 -ErrorAction SilentlyContinue |
                            ForEach-Object { [pscustomobject]@{ Time = $_.TimeCreated; Id = $_.Id; Level = $_.LevelDisplayName; Message = (($_.Message -split "`r?`n")[0]) } })
        }
    }
    $clustersSeen = @{}
    foreach ($g in $AvailabilityGroups) {
        $info = $null; $lastErr = $null
        foreach ($n in $g.Nodes) {
            try { $info = Invoke-Command -ComputerName $n -ScriptBlock $clusterBlock -ArgumentList $ErrorLogHours -ErrorAction Stop; break }
            catch { $lastErr = $_.Exception.Message }
        }
        if (-not $info) {
            Add-Cause $g.Name "Could not read the cluster for $($g.Name) through remoting: $lastErr" "Check WinRM on $($g.Nodes -join ' / ') and that this account is local admin there."
            continue
        }
        if ($clustersSeen.ContainsKey($info.Cluster)) { continue }
        $clustersSeen[$info.Cluster] = $true
        $info.Nodes     | ForEach-Object { $diag.ClusterNodes.Add([pscustomobject]@{ Cluster = $info.Cluster; Node = $_.Name; State = $_.State; Status = $_.Status }) }
        $info.Resources | ForEach-Object { $diag.AGResources.Add([pscustomobject]@{ Cluster = $info.Cluster; Resource = $_.Name; State = $_.State; OwnerNode = $_.OwnerNode }) }
        $info.Events    | ForEach-Object { $diag.ClusterEvents.Add([pscustomobject]@{ Cluster = $info.Cluster; Time = $_.Time; Id = $_.Id; Level = $_.Level; Message = $_.Message }) }
    }

    # ---------------------------------------------------------------- likely causes (rules)

    # Cluster nodes: down, paused, quarantined, isolated
    foreach ($cn in $diag.ClusterNodes) {
        if ($cn.Status -match 'Quarantin') {
            Add-Cause "$($cn.Cluster) / $($cn.Node)" "Node is QUARANTINED: the cluster removed it after it left the cluster repeatedly, and will keep it out (2 hours by default)." "Find why it kept dropping (network, the VM host pausing, CPU starvation; see the cluster events below). Then: Start-ClusterNode -Name $($cn.Node) -ClearQuarantine"
        }
        elseif ($cn.Status -match 'Isolat') {
            Add-Cause "$($cn.Cluster) / $($cn.Node)" "Node is ISOLATED: it lost communication with the other cluster nodes but is still running." "Check the network between the nodes (NIC, switch, VM network). It rejoins on its own once heartbeats return."
        }
        if ($cn.State -eq 'Down') {
            Add-Cause "$($cn.Cluster) / $($cn.Node)" "Cluster node is DOWN." "Check the server is powered on and the Cluster service is running (Get-Service ClusSvc). Start-ClusterNode -Name $($cn.Node)"
        }
        elseif ($cn.State -eq 'Paused') {
            Add-Cause "$($cn.Cluster) / $($cn.Node)" "Cluster node is PAUSED (drained), so it can't host roles." "If maintenance is finished: Resume-ClusterNode -Name $($cn.Node)"
        }
    }

    # Quorum
    foreach ($q in ($diag.Quorum | Where-Object { $_.QuorumState -and $_.QuorumState -ne 'NORMAL_QUORUM' })) {
        Add-Cause "$($q.ClusterName) (seen from $($q.Node))" "Cluster quorum is $($q.QuorumState). Without quorum the AG goes to RESOLVING and no node can be primary." "Bring the down nodes or the witness back. Forcing quorum (Start-ClusterNode -FixQuorum) is a last resort with data-loss risk."
    }

    # AG cluster resource
    foreach ($res in ($diag.AGResources | Where-Object { $_.State -ne 'Online' })) {
        Add-Cause "$($res.Cluster) / $($res.Resource)" "AG cluster resource is $($res.State) (owner $($res.OwnerNode))." "Read the cluster events and the SQL error log on $($res.OwnerNode) below for why it went $($res.State). Once the cause is fixed: Start-ClusterResource -Name '$($res.Resource)'"
    }

    # RESOLVING
    foreach ($nr in ($diag.NodeReplicas | Where-Object { $_.IsLocal -and $_.Role -eq 'RESOLVING' })) {
        Add-Cause "$($nr.AGName) / $($nr.Node)" "Replica is RESOLVING: it doesn't know whether it is primary or secondary." "Usually a cluster problem (lost quorum, lease timeout, AG resource offline). Check the cluster findings first."
    }

    # Endpoints
    foreach ($ep in ($diag.Endpoints | Where-Object { $_.State -ne 'STARTED' })) {
        Add-Cause "$($ep.Node)" "Mirroring endpoint [$($ep.EndpointName)] is $($ep.State), so this node can't send or receive AG data." "ALTER ENDPOINT [$($ep.EndpointName)] STATE = STARTED;  (run on $($ep.Node))"
    }

    # Connection errors between replicas (recent)
    $since = (Get-Date).AddHours(-$ErrorLogHours)
    $seenErr = @{}
    foreach ($nr in ($diag.NodeReplicas | Where-Object { $_.LastErrNo -and $_.LastErrNo -ne [DBNull]::Value -and $_.LastErrNo -ne 0 })) {
        $t = $nr.LastErrTime
        if ($t -and $t -ne [DBNull]::Value -and [datetime]$t -lt $since) { continue }
        $key = "$($nr.AGName)|$($nr.Node)|$($nr.Replica)|$($nr.LastErrNo)"
        if ($seenErr.ContainsKey($key)) { continue }; $seenErr[$key] = $true
        Add-Cause "$($nr.AGName): $($nr.Node) -> $($nr.Replica)" "Last connection error $($nr.LastErrNo) at $($nr.LastErrTime): $($nr.LastErrText)" "Check the endpoint port is open between the two nodes (Test-NetConnection $($nr.Replica) -Port <endpoint port>) and the service account has CONNECT on the endpoint."
    }

    # Database state, suspended data movement
    foreach ($nd in $diag.NodeDatabases) {
        if ($nd.DatabaseState -ne 'ONLINE' -and $nd.DatabaseState -ne 'RESTORING') {
            Add-Cause "$($nd.AGName) / $($nd.Node) / $($nd.DatabaseName)" "Database is $($nd.DatabaseState)." "If RECOVERING, give it time and watch the error log. If RECOVERY_PENDING or SUSPECT, check the error log for the file or log error behind it."
        }
        if ($nd.IsSuspended -eq $true) {
            Add-Cause "$($nd.AGName) / $($nd.Node) / $($nd.DatabaseName)" "Data movement is SUSPENDED (reason: $($nd.SuspendReason))." "Fix the reason first (see the error log), then on $($nd.Node): ALTER DATABASE [$($nd.DatabaseName)] SET HADR RESUME;"
        }
    }

    # Unexpected primary (the first node listed is the preferred primary)
    foreach ($g in $AvailabilityGroups) {
        $p = $primaries[$g.Name]
        if ($p -and $p -ne @($g.Nodes)[0]) {
            $roleMsg = $diag.ErrorLog | Where-Object { $_.Text -like '*changing roles*' -and $_.Node -in $g.Nodes } | Sort-Object LogDate -Descending | Select-Object -First 1
            $detail = if ($roleMsg) { " Last role change $($roleMsg.LogDate) on $($roleMsg.Node): $($roleMsg.Text)" } else { " No role-change message in the last $ErrorLogHours hours of the error log." }
            Add-Cause $g.Name "Failover happened: $p is primary, the preferred primary is $(@($g.Nodes)[0]).$detail" "Find out why from the cluster events and error log. Once healthy, fail back with ALTER AVAILABILITY GROUP [$($g.Name)] FAILOVER; on $(@($g.Nodes)[0])."
        }
    }

    # DAG link
    if ($DagName) {
        $dagBad   = @($replicas | Where-Object { $_.AGName -eq $DagName -and ($_.Connected -ne 'CONNECTED' -or $_.Health -ne 'HEALTHY') }).Count -gt 0
        $localBad = @($AvailabilityGroups | Where-Object { $n = $_.Name; @($replicas | Where-Object { $_.AGName -eq $n -and $_.Health -ne 'HEALTHY' }).Count -gt 0 }) | ForEach-Object { $_.Name }
        if ($dagBad -and $localBad) {
            Add-Cause $DagName "The DAG is unhealthy because $($localBad -join ', ') is unhealthy underneath it." "Fix $($localBad -join ', ') first; the DAG link usually recovers on its own afterwards."
        }
        elseif ($dagBad) {
            Add-Cause $DagName "The DAG link is unhealthy while both AGs are healthy." "Check the listener endpoints in the DAG (sys.availability_replicas.endpoint_url), DNS for the listeners, and that port 5022 (or yours) is open between the two sides."
        }
    }

    # Nothing specific found
    if ($problems.Count -gt 0 -and $causes.Count -eq 0) {
        Add-Cause 'All' "No specific cause found by the checks." "Read the error log and cluster event tables below, then the AlwaysOn_health Extended Events session on the primary."
    }
}

# ---------------------------------------------------------------- output

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

if ($runDiag) {
    Write-Host "`n===== Diagnostics =====" -ForegroundColor Cyan
    if ($causes.Count) {
        Write-Host "`nLikely causes (most important first: cluster, then connectivity, then databases)" -ForegroundColor Yellow
        $i = 0
        foreach ($c in $causes) {
            $i++
            Write-Host ("`n {0}. [{1}] {2}" -f $i, $c.Where, $c.Finding) -ForegroundColor Yellow
            Write-Host ("    Try first: {0}" -f $c.TryFirst)
        }
    }
    else { Write-Host "`nNo problems found by the diagnostics." -ForegroundColor Green }

    # Built key by key: Windows PowerShell 5.1 throws "Argument types do not match" on an
    # [ordered] literal whose keys contain variables.
    $sections = [ordered]@{}
    $sections['Cluster nodes']                     = $diag.ClusterNodes
    $sections['AG cluster resources']              = $diag.AGResources
    $sections['Quorum (as each node sees it)']     = $diag.Quorum
    $sections['Replicas (as each node sees them)'] = @($diag.NodeReplicas | Select-Object Node, AGName, Replica, Role, OperationalState, RecoveryHealth, Connected, Health, LastErrNo, LastErrTime)
    $sections['Databases (local view per node)']   = $diag.NodeDatabases
    $sections['Mirroring endpoints']               = $diag.Endpoints
    $sections["Cluster events (last $ErrorLogHours h)"] = $diag.ClusterEvents
    $sections["SQL error log, Always On related (last $ErrorLogHours h)"] = $diag.ErrorLog
    foreach ($k in $sections.Keys) {
        if (@($sections[$k]).Count) {
            Write-Host "`n$k" -ForegroundColor Cyan
            $sections[$k] | Format-Table -AutoSize -Wrap | Out-String -Width 250 | Write-Host
        }
    }
}

if (-not $NoHtml) {
    New-Item -Path $ReportFolder -ItemType Directory -Force | Out-Null
    $htmlPath = Join-Path $ReportFolder ("AG-Status_{0}.html" -f (Get-Date -Format 'yyyyMMdd_HHmm'))
    $verdict = if ($problems.Count -eq 0) { "<p class='ok'>Overall: HEALTHY</p>" }
               else { "<p class='bad'>Overall: ISSUES FOUND</p><ul>" + (($problems | ForEach-Object { "<li>$([System.Net.WebUtility]::HtmlEncode($_))</li>" }) -join '') + "</ul>" }
    $style = @'
<style>
body { font-family: Segoe UI, Arial, sans-serif; font-size: 13px; margin: 20px; }
h1 { font-size: 18px; } h2 { font-size: 15px; margin-top: 24px; }
table { border-collapse: collapse; } th, td { border: 1px solid #ccc; padding: 4px 8px; text-align: left; vertical-align: top; }
th { background: #f0f0f0; } .ok { color: #1a7f37; font-weight: bold; } .bad { color: #c62828; font-weight: bold; }
</style>
'@
    $body = "<h1>AG status report - $stamp</h1>$verdict" +
            "<h2>Replicas</h2>"  + ($replicas  | ConvertTo-Html -Fragment | Out-String) +
            "<h2>Databases</h2>" + ($databases | ConvertTo-Html -Fragment | Out-String)
    if ($runDiag) {
        $body += "<h2>Likely causes</h2>" + ($causes | ConvertTo-Html -Fragment | Out-String)
        foreach ($k in $sections.Keys) {
            if (@($sections[$k]).Count) { $body += "<h2>$k</h2>" + ($sections[$k] | ConvertTo-Html -Fragment | Out-String) }
        }
    }
    ConvertTo-Html -Head $style -Body $body -Title 'AG status report' | Set-Content -Path $htmlPath -Encoding UTF8
    Write-Host "`nHTML report: $htmlPath" -ForegroundColor Cyan
}
