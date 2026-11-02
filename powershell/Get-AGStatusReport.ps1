<#
.SYNOPSIS
    Availability group (and distributed AG) status report that, when anything is wrong, tells you
    why: straight from the cluster log, the cluster events and the SQL Server error log.

.DESCRIPTION
    Status (always):
      Replicas   AG, replica, role, availability mode, failover mode, connected state, health
      Databases  AG, replica, database, sync state, health, log send / redo queue, last commit time
      Verdict    HEALTHY, or a list of exactly what is not

    Diagnosis (automatically when the verdict is not HEALTHY, or always with -Diagnose):
      Likely causes  Each problem in plain English, with the evidence behind it (how many times,
                     first and last time, where) and the fix to try first. It recognises:
                       - cluster node down, paused, quarantined or isolated; lost quorum;
                         AG cluster resource not online; replicas stuck RESOLVING
                       - lease timeouts, missed health checks, the cluster unable to connect to SQL,
                         nodes dropping out of the cluster (from the cluster log and events)
                       - CPU starvation (non-yielding schedulers) and slow I/O (from SQL errors)
                       - stopped endpoints and replica connection errors
                       - database not online, and suspended data movement with its reason
                       - an unexpected failover, with the role-change reason from the error log
                       - a broken DAG link versus an AG problem underneath it
      Evidence       Only what matters, grouped and counted:
                       - failure reasons from the failover cluster log (Get-ClusterLog)
                       - failover clustering events by event ID
                       - real SQL Server errors by error number (informational messages dropped)
                       - only the abnormal rows of the cluster, replica, database and endpoint views
                     -Detailed shows the full tables as well.

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
    Parameters passed on the command line win over the file.

.PARAMETER Diagnose
    Run the diagnosis even when everything is healthy.

.PARAMETER Detailed
    Also show the full cluster, replica, database and endpoint tables, not only abnormal rows.

.PARAMETER ErrorLogHours
    How far back to read the cluster log, cluster events and SQL Server error log.

.PARAMETER NoClusterLog
    Skip generating the cluster log (it takes 20 to 60 seconds per cluster).

.PARAMETER ReportFolder
    Where the HTML copy is saved.

.PARAMETER NoHtml
    Console output only.

.EXAMPLE
    .\Get-AGStatusReport.ps1          # uses ag-config.psd1 next to the script

.EXAMPLE
    .\Get-AGStatusReport.ps1 -Diagnose -ErrorLogHours 48 -Detailed

.NOTES
    Read-only. Run from a management machine or any server that can reach every node.
    Needs VIEW SERVER STATE on every instance (sysadmin is simplest). The cluster checks use
    PowerShell remoting to one node per AG and need local admin there; if remoting fails the
    report still runs and says the cluster could not be checked.
    The cluster log is written to %TEMP%\AGStatusClusterLog on that node and replaced each run.
    Windows PowerShell 5.1.
#>
[CmdletBinding()]
param(
    [hashtable[]]$AvailabilityGroups,
    [string]$DagName,
    [int]$SqlPort = 1433,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'ag-config.psd1'),
    [switch]$Diagnose,
    [switch]$Detailed,
    [int]$ErrorLogHours = 24,
    [switch]$NoClusterLog,
    [string]$ReportFolder = 'C:\Scripts\Logs_AGStatus',
    [switch]$NoHtml
)

$ErrorActionPreference = 'Stop'

# Any unexpected error: say exactly where, so it can be fixed, instead of a bare message.
trap {
    Write-Host ("`nGet-AGStatusReport stopped at line {0}: {1}" -f $_.InvocationInfo.ScriptLineNumber, $_.Exception.Message) -ForegroundColor Red
    Write-Host ("  {0}" -f $_.InvocationInfo.Line.Trim()) -ForegroundColor DarkGray
    break
}

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
    ClusterLog   = New-Object System.Collections.Generic.List[object]
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

    # Real SQL Server errors only, grouped: error number, how many times, first and last time.
    # Reads the current and the previous error log (so a restart doesn't hide last night).
    # "Error: N" header lines are joined to the message line that follows them. Role changes and
    # lease messages are kept even without an error number because they carry the reason.
    $qErrorLog = @"
SET NOCOUNT ON;
CREATE TABLE #el (id int IDENTITY(1,1), LogDate datetime, ProcessInfo nvarchar(100), [Text] nvarchar(max));
BEGIN TRY INSERT #el (LogDate, ProcessInfo, [Text]) EXEC master.dbo.xp_readerrorlog 1, 1; END TRY BEGIN CATCH END CATCH;
INSERT #el (LogDate, ProcessInfo, [Text]) EXEC master.dbo.xp_readerrorlog 0, 1;

WITH errs AS (
    SELECT e.LogDate, SUBSTRING(e.[Text], 8, CHARINDEX(',', e.[Text]) - 8) AS ErrorNo, n.[Text] AS Msg
    FROM #el e
    JOIN #el n ON n.id = e.id + 1
    WHERE e.[Text] LIKE 'Error: %' AND CHARINDEX(',', e.[Text]) > 8
),
k AS (
    SELECT x.LogDate, '' AS ErrorNo, x.[Text] AS Msg
    FROM #el x
    WHERE (   x.[Text] LIKE '%changing roles%'
           OR x.[Text] LIKE '%lease%expired%' OR x.[Text] LIKE '%lease%timeout%' OR x.[Text] LIKE '%lease%failed%'
           OR x.[Text] LIKE '%connection timeout%' OR x.[Text] LIKE '%has been suspended%')
      AND NOT EXISTS (SELECT 1 FROM #el p WHERE p.id = x.id - 1 AND p.[Text] LIKE 'Error: %')
),
allrows AS (SELECT LogDate, ErrorNo, Msg FROM errs UNION ALL SELECT LogDate, ErrorNo, Msg FROM k)
SELECT TOP (15)
       ErrorNo, COUNT(*) AS Times, MIN(LogDate) AS FirstSeen, MAX(LogDate) AS LastSeen,
       LEFT(Msg, 300) AS Message
FROM allrows
WHERE LogDate >= DATEADD(HOUR, -$ErrorLogHours, GETDATE())
  AND ErrorNo NOT IN ('41145', '18456', '0')
  AND (Msg NOT LIKE '%informational message%' OR Msg LIKE '%changing roles%')
GROUP BY ErrorNo, LEFT(Msg, 300)
ORDER BY MAX(LogDate) DESC;
DROP TABLE #el;
"@

    # ---- per node: SQL view ----
    foreach ($n in $allNodes) {
        try {
            Invoke-StatusSql $n $qNodeReplicas  | Select-Object @{n='Node';e={$n}}, AGName, Replica, IsLocal, Role, OperationalState, RecoveryHealth, Connected, Health, LastErrNo, LastErrText, LastErrTime | ForEach-Object { $diag.NodeReplicas.Add($_) }
            Invoke-StatusSql $n $qNodeDatabases | Select-Object @{n='Node';e={$n}}, AGName, DatabaseName, DatabaseState, SyncState, Health, IsSuspended, SuspendReason, LagSeconds, LastHardened | ForEach-Object { $diag.NodeDatabases.Add($_) }
            Invoke-StatusSql $n $qEndpoints     | Select-Object @{n='Node';e={$n}}, EndpointName, State, Port | ForEach-Object { $diag.Endpoints.Add($_) }
            Invoke-StatusSql $n $qQuorum        | Select-Object @{n='Node';e={$n}}, ClusterName, QuorumType, QuorumState | ForEach-Object { $diag.Quorum.Add($_) }
        }
        catch {
            Add-Cause $n "Can't query SQL Server on ${n}: $($_.Exception.Message)" "Check the node is up, the SQL Server service is running, and port $SqlPort is reachable (Test-NetConnection $n -Port $SqlPort)."
            continue
        }
        try {
            Invoke-StatusSql $n $qErrorLog | Select-Object @{n='Node';e={$n}}, ErrorNo, Times, FirstSeen, LastSeen, Message | ForEach-Object { $diag.ErrorLog.Add($_) }
        }
        catch { Write-Host "  (could not read the SQL error log on ${n}: $($_.Exception.Message))" -ForegroundColor DarkYellow }
    }

    # ---- per AG: cluster view (each AG of a DAG is its own cluster) ----
    $clusterBlock = {
        param($hours, $skipLog)
        Import-Module FailoverClusters -ErrorAction Stop
        $cl = Get-Cluster

        # Failure reasons from the cluster log: ERR/WARN lines that explain failures, grouped
        $reasons = New-Object System.Collections.Generic.List[object]
        if (-not $skipLog) {
            try {
                $dir = Join-Path $env:TEMP 'AGStatusClusterLog'
                if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
                New-Item -Path $dir -ItemType Directory | Out-Null
                Get-ClusterLog -TimeSpan ($hours * 60) -UseLocalTime -Destination $dir | Out-Null
                $pattern = 'lease|heartbeat is lost|HealthCheckTimeout|not healthy|Connect to SQL Server instance failed|ODBC|-->Failed|ProcessingFailure|removed from the active failover cluster|quorum|failure count|timed out|timeout|failed to'
                foreach ($f in (Get-ChildItem $dir -Filter *.log)) {
                    $nodeName = $f.BaseName -replace '_cluster$', ''
                    $hits = Select-String -Path $f.FullName -Pattern $pattern | ForEach-Object {
                        $line = $_.Line
                        if ($line -notmatch '\s(ERR|WARN)\s') { return }
                        $ts = $null
                        if ($line -match '::(\d{4}/\d{2}/\d{2}-\d{2}:\d{2}:\d{2})') { $ts = [datetime]::ParseExact($Matches[1], 'yyyy/MM/dd-HH:mm:ss', $null) }
                        $msg = ($line -replace '^.*?::\S+\s+(INFO|WARN|ERR|DBG)\s+', '').Trim()
                        [pscustomobject]@{ Time = $ts; Key = ($msg -replace '\d{3,}', '#' -replace '\{[0-9a-fA-F-]+\}', '{id}'); Message = $msg }
                    }
                    foreach ($grp in @($hits | Group-Object Key)) {
                        $items = @($grp.Group | Sort-Object Time)
                        $last  = $items[$items.Count - 1]
                        $text  = if ($last.Message.Length -gt 250) { $last.Message.Substring(0, 250) } else { $last.Message }
                        $reasons.Add([pscustomobject]@{ Node = $nodeName; Times = $grp.Count; First = $items[0].Time; Last = $last.Time; Message = $text })
                    }
                }
            }
            catch { $reasons.Add([pscustomobject]@{ Node = $env:COMPUTERNAME; Times = 0; First = $null; Last = $null; Message = "Could not read the cluster log: $($_.Exception.Message)" }) }
        }

        [pscustomobject]@{
            Cluster   = $cl.Name
            Nodes     = @(Get-ClusterNode | ForEach-Object {
                            [pscustomobject]@{ Name = $_.Name; State = "$($_.State)"; Status = "$($_.StatusInformation)" } })
            Resources = @(Get-ClusterResource | Where-Object ResourceType -eq 'SQL Server Availability Group' | ForEach-Object {
                            [pscustomobject]@{ Name = $_.Name; State = "$($_.State)"; OwnerNode = "$($_.OwnerNode)" } })
            Events    = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-FailoverClustering'; StartTime = (Get-Date).AddHours(-$hours) } -MaxEvents 200 -ErrorAction SilentlyContinue |
                            Where-Object { $_.Level -le 3 } |
                            ForEach-Object { [pscustomobject]@{ Time = $_.TimeCreated; Id = $_.Id; Level = $_.LevelDisplayName; Message = (($_.Message -split "`r?`n")[0]) } })
            Reasons   = @($reasons)
        }
    }
    $clustersSeen = @{}
    foreach ($g in $AvailabilityGroups) {
        $info = $null; $lastErr = $null
        foreach ($n in $g.Nodes) {
            try { $info = Invoke-Command -ComputerName $n -ScriptBlock $clusterBlock -ArgumentList $ErrorLogHours, $NoClusterLog.IsPresent -ErrorAction Stop; break }
            catch { $lastErr = $_.Exception.Message }
        }
        if (-not $info) {
            Add-Cause $g.Name "Could not read the cluster for $($g.Name) through remoting: $lastErr" "Check WinRM on $($g.Nodes -join ' / ') and that this account is local admin there."
            continue
        }
        if ($clustersSeen.ContainsKey($info.Cluster)) { continue }
        $clustersSeen[$info.Cluster] = $true
        foreach ($x in @($info.Nodes))     { $diag.ClusterNodes.Add([pscustomobject]@{ Cluster = $info.Cluster; Node = $x.Name; State = $x.State; Status = $x.Status }) }
        foreach ($x in @($info.Resources)) { $diag.AGResources.Add([pscustomobject]@{ Cluster = $info.Cluster; Resource = $x.Name; State = $x.State; OwnerNode = $x.OwnerNode }) }
        foreach ($x in @($info.Events))    { $diag.ClusterEvents.Add([pscustomobject]@{ Cluster = $info.Cluster; Time = $x.Time; Id = $x.Id; Level = $x.Level; Message = $x.Message }) }
        foreach ($x in @($info.Reasons))   { $diag.ClusterLog.Add([pscustomobject]@{ Cluster = $info.Cluster; Node = $x.Node; Times = $x.Times; First = $x.First; Last = $x.Last; Message = $x.Message }) }
    }

    # ---------------------------------------------------------------- likely causes (rules)

    # Cluster nodes: down, paused, quarantined, isolated
    foreach ($cn in $diag.ClusterNodes) {
        if ($cn.Status -match 'Quarantin') {
            Add-Cause "$($cn.Cluster) / $($cn.Node)" "Node is QUARANTINED: the cluster removed it after it left the cluster repeatedly, and will keep it out (2 hours by default)." "Find why it kept dropping (see the evidence below), then: Start-ClusterNode -Name $($cn.Node) -ClearQuarantine"
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
        Add-Cause "$($res.Cluster) / $($res.Resource)" "AG cluster resource is $($res.State) (owner $($res.OwnerNode))." "See the failure reasons below. Once the cause is fixed: Start-ClusterResource -Name '$($res.Resource)'"
    }

    # RESOLVING
    foreach ($nr in ($diag.NodeReplicas | Where-Object { $_.IsLocal -and $_.Role -eq 'RESOLVING' })) {
        Add-Cause "$($nr.AGName) / $($nr.Node)" "Replica is RESOLVING: it doesn't know whether it is primary or secondary." "Usually a cluster problem (lost quorum, lease timeout, AG resource offline). See the cluster findings."
    }

    # Known failure signatures: matched against the cluster log, the cluster events and the SQL errors.
    # Each one turns into a single finding with the evidence (how many times, first, last, where).
    $signatures = @(
        @{ Name = 'Lease timeout';
           Log = '(?i)lease.*(expir|time ?out|timed out|fail|terminat)'; Events = @(); Errors = @('19407','19419','19421','19422');
           Finding = 'SQL Server could not renew its lease with the cluster in time, so the cluster took the AG offline or failed it over.';
           Fix = 'The node was frozen or starved for longer than LeaseTimeout (20 s by default): VM host sleeping or suspended, a snapshot, CPU or memory starvation, very slow disk. Fix the host. In a lab you can raise LeaseTimeout on the AG cluster resource.' }
        @{ Name = 'Health check';
           Log = '(?i)heartbeat is lost|HealthCheckTimeout|not healthy with given|state of system component is error'; Events = @(); Errors = @();
           Finding = 'SQL Server did not answer the cluster health check in time (HealthCheckTimeout, 30 s by default) or reported an unhealthy component.';
           Fix = 'Same causes as a lease timeout: the node frozen or starved. If it recurs on a busy server, review HealthCheckTimeout and FailureConditionLevel on the AG.' }
        @{ Name = 'Cluster cannot connect to SQL';
           Log = '(?i)Connect to SQL Server instance failed|ODBC Error'; Events = @(); Errors = @();
           Finding = 'The cluster could not connect to SQL Server to check the AG.';
           Fix = 'Check the SQL Server service was running at that time, and that NT AUTHORITY\SYSTEM has CONNECT SQL, VIEW SERVER STATE and ALTER ANY AVAILABILITY GROUP.' }
        @{ Name = 'Node dropped out';
           Log = '(?i)removed from the active failover cluster membership|lost communication with'; Events = @(1135, 1006); Errors = @();
           Finding = 'A node dropped out of the cluster after missing heartbeats.';
           Fix = 'The network between the nodes, or the VM paused. Check the host and the VM network adapters.' }
        @{ Name = 'Quorum lost';
           Log = '(?i)quorum (was )?lost|lost quorum|loss of quorum'; Events = @(1177); Errors = @();
           Finding = 'The cluster lost quorum, so every role on it went offline.';
           Fix = 'Too many nodes (or the witness) were unreachable at once. Check why they dropped, and consider a file share or cloud witness.' }
        @{ Name = 'CPU starvation';
           Log = ''; Events = @(); Errors = @('17883','17884','17888');
           Finding = 'SQL Server reported non-yielding or deadlocked schedulers.';
           Fix = 'The VM was starved of CPU or paused. Check host CPU and what else runs on the host.' }
        @{ Name = 'Slow I/O';
           Log = ''; Events = @(); Errors = @('833');
           Finding = 'SQL Server reported I/O requests taking longer than 15 seconds.';
           Fix = 'Storage is too slow or the host disk is saturated. Check host disk latency.' }
        @{ Name = 'Replica connection timeouts';
           Log = ''; Events = @(); Errors = @('35206','35201');
           Finding = 'Replicas timed out connecting to each other.';
           Fix = 'Normal right after a node pause or restart. If it keeps happening, check the endpoint port between the nodes.' }
    )
    foreach ($s in $signatures) {
        $ev = New-Object System.Collections.Generic.List[object]
        if ($s.Log) {
            foreach ($x in ($diag.ClusterLog | Where-Object { $_.Message -match $s.Log })) {
                $ev.Add([pscustomobject]@{ Where = "$($x.Node) cluster log"; Times = $x.Times; First = $x.First; Last = $x.Last })
            }
            foreach ($x in ($diag.ErrorLog | Where-Object { $_.ErrorNo -eq '' -and $_.Message -match $s.Log })) {
                $ev.Add([pscustomobject]@{ Where = "$($x.Node) SQL error log"; Times = $x.Times; First = $x.FirstSeen; Last = $x.LastSeen })
            }
        }
        foreach ($x in ($diag.ClusterEvents | Where-Object { $s.Events -contains $_.Id })) {
            $ev.Add([pscustomobject]@{ Where = "$($x.Cluster) event $($x.Id)"; Times = 1; First = $x.Time; Last = $x.Time })
        }
        foreach ($x in ($diag.ErrorLog | Where-Object { $s.Errors -contains "$($_.ErrorNo)" })) {
            $ev.Add([pscustomobject]@{ Where = "$($x.Node) SQL error $($x.ErrorNo)"; Times = $x.Times; First = $x.FirstSeen; Last = $x.LastSeen })
        }
        if ($ev.Count) {
            $total = ($ev | Measure-Object Times -Sum).Sum
            $first = ($ev | Where-Object { $_.First } | Sort-Object First | Select-Object -First 1).First
            $last  = ($ev | Where-Object { $_.Last }  | Sort-Object Last -Descending | Select-Object -First 1).Last
            $where = (($ev | ForEach-Object { $_.Where }) | Select-Object -Unique) -join ', '
            Add-Cause $s.Name ("{0} Seen {1} time(s), first {2}, last {3}, in: {4}." -f $s.Finding, $total, $first, $last, $where) $s.Fix
        }
    }

    # Repeated AG resource failures / failover threshold reached (from the cluster events)
    foreach ($clName in @($diag.ClusterEvents | ForEach-Object { $_.Cluster } | Select-Object -Unique)) {
        $evts      = @($diag.ClusterEvents | Where-Object { $_.Cluster -eq $clName })
        $failed    = @($evts | Where-Object { $_.Id -eq 1069 })
        $threshold = @($evts | Where-Object { $_.Id -eq 1254 })
        if ($failed.Count -ge 2 -or $threshold.Count -ge 1) {
            $first = ($failed | Sort-Object Time | Select-Object -First 1).Time
            $last  = ($evts   | Sort-Object Time -Descending | Select-Object -First 1).Time
            $msg = "AG resource failed $($failed.Count) times in the last $ErrorLogHours h (first $first, latest $last)"
            if ($threshold.Count) { $msg += "; the cluster hit the failover threshold $($threshold.Count) time(s) and left the role failed (event 1254)" }
            Add-Cause $clName ($msg + ".") "The findings above say why it failed. If none do, look at the cluster log on the owner node: Get-ClusterLog -TimeSpan 120 -UseLocalTime -Destination C:\Temp"
        }
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
            Add-Cause "$($nd.AGName) / $($nd.Node) / $($nd.DatabaseName)" "Database is $($nd.DatabaseState)." "If RECOVERING, give it time and watch the error log. If RECOVERY_PENDING or SUSPECT, check the SQL errors below for the file or log error behind it."
        }
        if ($nd.IsSuspended -eq $true) {
            $resume = "ALTER DATABASE [$($nd.DatabaseName)] SET HADR RESUME;  (run on $($nd.Node))"
            $why = switch ($nd.SuspendReason) {
                'SUSPEND_FROM_USER'     { "Someone suspended it by hand. If that work is finished: $resume" }
                'SUSPEND_FROM_RESTART'  { "It was suspended when SQL Server restarted. If the SQL errors below show no database problem: $resume" }
                'SUSPEND_FROM_REDO'     { "Redo hit an error while applying log. Check the SQL errors below (disk space, file, corruption), fix it, then: $resume" }
                'SUSPEND_FROM_UNDO'     { "Undo hit an error after a failover. Check the SQL errors below, fix it, then: $resume" }
                'SUSPEND_FROM_CAPTURE'  { "Log capture on the primary hit an error. Check the SQL errors below, fix it, then: $resume" }
                'SUSPEND_FROM_APPLY'    { "Applying log on the secondary hit an error. Check the SQL errors below, fix it, then: $resume" }
                default                 { "Fix the reason first (see the SQL errors below), then: $resume" }
            }
            Add-Cause "$($nd.AGName) / $($nd.Node) / $($nd.DatabaseName)" "Data movement is SUSPENDED (reason: $($nd.SuspendReason))." $why
        }
    }

    # Unexpected primary (the first node listed is the preferred primary)
    foreach ($g in $AvailabilityGroups) {
        $p = $primaries[$g.Name]
        if ($p -and $p -ne @($g.Nodes)[0]) {
            $roleMsg = $diag.ErrorLog | Where-Object { $_.Message -like '*changing roles*' -and $_.Node -in $g.Nodes } | Sort-Object LastSeen -Descending | Select-Object -First 1
            $detail = if ($roleMsg) { " Last role change $($roleMsg.LastSeen) on $($roleMsg.Node): $($roleMsg.Message)" } else { " No role-change message in the error logs for the last $ErrorLogHours hours." }
            Add-Cause $g.Name "Failover happened: $p is primary, the preferred primary is $(@($g.Nodes)[0]).$detail" "The findings above say what caused it. Once healthy, fail back with ALTER AVAILABILITY GROUP [$($g.Name)] FAILOVER; on $(@($g.Nodes)[0])."
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
        Add-Cause 'All' "No specific cause found by the checks." "Rerun with -Detailed, and check the AlwaysOn_health Extended Events session on the primary."
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

$sectionTitles = New-Object System.Collections.Generic.List[string]
$sectionRows   = New-Object System.Collections.Generic.List[object]

if ($runDiag) {
    Write-Host "`n===== Diagnosis =====" -ForegroundColor Cyan
    if ($causes.Count) {
        Write-Host "`nLikely causes (cluster first, then why it failed, then connectivity, then databases)" -ForegroundColor Yellow
        $i = 0
        foreach ($c in $causes) {
            $i++
            Write-Host ("`n {0}. [{1}] {2}" -f $i, $c.Where, $c.Finding) -ForegroundColor Yellow
            Write-Host ("    Try first: {0}" -f $c.TryFirst)
        }
    }
    else { Write-Host "`nNo problems found by the diagnosis." -ForegroundColor Green }

    function Add-Section([string]$Title, $Rows) { $sectionTitles.Add($Title); $sectionRows.Add($Rows) }
    function Show-Section([string]$Title, $Rows) {
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($r in $Rows) { $list.Add($r) }
        if ($list.Count -eq 0) { return }
        Write-Host ""
        Write-Host $Title -ForegroundColor Cyan
        try {
            $text = $list | Format-Table -AutoSize -Wrap | Out-String -Width 250
            Write-Host $text
        }
        catch {
            foreach ($r in $list) {
                $parts = foreach ($p in $r.PSObject.Properties) { "{0}={1}" -f $p.Name, $p.Value }
                Write-Host ("  " + ($parts -join ' | '))
            }
        }
    }

    try {
        # Evidence, grouped and counted
        $eventSummary = foreach ($grp in @($diag.ClusterEvents | Group-Object Cluster, Id)) {
            $items = @($grp.Group | Sort-Object Time)
            $last  = $items[$items.Count - 1]
            [pscustomobject]@{ Cluster = $last.Cluster; EventId = $last.Id; Times = $grp.Count; First = $items[0].Time; Last = $last.Time; Message = $last.Message }
        }
        Add-Section ('Why it failed: cluster log (last {0} h, errors and warnings that explain failures)' -f $ErrorLogHours) ($diag.ClusterLog | Sort-Object Last -Descending)
        Add-Section ('Cluster events, errors and warnings (last {0} h)' -f $ErrorLogHours) ($eventSummary | Sort-Object Last -Descending)
        Add-Section ('SQL Server errors (last {0} h, informational messages removed)' -f $ErrorLogHours) ($diag.ErrorLog | Sort-Object LastSeen -Descending)

        if ($Detailed) {
            Add-Section 'Cluster nodes'                     $diag.ClusterNodes
            Add-Section 'AG cluster resources'              $diag.AGResources
            Add-Section 'Quorum (as each node sees it)'     $diag.Quorum
            Add-Section 'Replicas (as each node sees them)' ($diag.NodeReplicas | Select-Object Node, AGName, Replica, Role, OperationalState, RecoveryHealth, Connected, Health, LastErrNo, LastErrTime)
            Add-Section 'Databases (local view per node)'   $diag.NodeDatabases
            Add-Section 'Mirroring endpoints'               $diag.Endpoints
        }
        else {
            # Only what is not normal
            Add-Section 'Cluster nodes not Up / Normal'     ($diag.ClusterNodes | Where-Object { $_.State -ne 'Up' -or ($_.Status -and $_.Status -ne 'Normal') })
            Add-Section 'AG cluster resources not Online'   ($diag.AGResources  | Where-Object { $_.State -ne 'Online' })
            Add-Section 'Quorum not normal'                 ($diag.Quorum       | Where-Object { $_.QuorumState -ne 'NORMAL_QUORUM' })
            Add-Section 'Unhealthy replicas (as each node sees them)' ($diag.NodeReplicas | Where-Object { $_.Health -and $_.Health -ne 'HEALTHY' } | Select-Object Node, AGName, Replica, Role, OperationalState, RecoveryHealth, Connected, Health)
            Add-Section 'Unhealthy databases (local view per node)'   ($diag.NodeDatabases | Where-Object { $_.Health -ne 'HEALTHY' -or $_.IsSuspended -eq $true -or $_.DatabaseState -ne 'ONLINE' } | Select-Object Node, AGName, DatabaseName, DatabaseState, SyncState, IsSuspended, SuspendReason, LastHardened)
            Add-Section 'Endpoints not started'             ($diag.Endpoints    | Where-Object { $_.State -ne 'STARTED' })
        }

        for ($i = 0; $i -lt $sectionTitles.Count; $i++) {
            try { Show-Section $sectionTitles[$i] $sectionRows[$i] }
            catch { Write-Host ("  Could not show '{0}' (line {1}): {2}" -f $sectionTitles[$i], $_.InvocationInfo.ScriptLineNumber, $_.Exception.Message) -ForegroundColor DarkYellow }
        }
        if (-not $Detailed) { Write-Host "`n(Add -Detailed for the full cluster, replica, database and endpoint tables.)" -ForegroundColor DarkGray }
    }
    catch {
        Write-Host ("`nEvidence tables failed at line {0}: {1}" -f $_.InvocationInfo.ScriptLineNumber, $_.Exception.Message) -ForegroundColor DarkYellow
    }
}

if (-not $NoHtml) {
    try {
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
            for ($i = 0; $i -lt $sectionTitles.Count; $i++) {
                $rows = @($sectionRows[$i])
                if ($rows.Count) { $body += "<h2>$($sectionTitles[$i])</h2>" + ($rows | ConvertTo-Html -Fragment | Out-String) }
            }
        }
        ConvertTo-Html -Head $style -Body $body -Title 'AG status report' | Set-Content -Path $htmlPath -Encoding UTF8
        Write-Host "`nHTML report: $htmlPath" -ForegroundColor Cyan
    }
    catch { Write-Host "`nCould not write the HTML report: $($_.Exception.Message)" -ForegroundColor DarkYellow }
}
