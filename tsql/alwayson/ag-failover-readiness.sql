/*
Script  : ag-failover-readiness.sql
Purpose : Pre-failover check for a planned (no data loss) failover. Shows, for
          the target replica, whether it is synchronous, connected, and whether
          every database is SYNCHRONIZED and failover ready. Also prints the
          failover command to run on the target.
Usage   : Set @AGName and @TargetReplica. Run on the current primary.
          is_failover_ready must be 1 for every database before you fail over.
Changes : Read-only. The failover command is printed, not executed.
Requires: SQL Server 2016 and later.
*/
DECLARE @AGName        sysname = N'YourAGName';
DECLARE @TargetReplica sysname = N'TargetReplicaName';

SELECT
    ag.name                             AS ag_name,
    ar.replica_server_name,
    ar.availability_mode_desc,          -- must be SYNCHRONOUS_COMMIT for a planned failover
    ar.failover_mode_desc,
    ars.role_desc,
    ars.connected_state_desc,
    ars.synchronization_health_desc,
    drcs.database_name,
    drcs.is_failover_ready,             -- must be 1
    drs.synchronization_state_desc      -- must be SYNCHRONIZED
FROM sys.availability_groups AS ag
JOIN sys.availability_replicas AS ar ON ar.group_id = ag.group_id
JOIN sys.dm_hadr_availability_replica_states AS ars ON ars.replica_id = ar.replica_id
LEFT JOIN sys.dm_hadr_database_replica_cluster_states AS drcs ON drcs.replica_id = ar.replica_id
LEFT JOIN sys.dm_hadr_database_replica_states AS drs
       ON drs.replica_id = ar.replica_id
      AND drs.group_database_id = drcs.group_database_id
WHERE ag.name = @AGName
  AND ar.replica_server_name = @TargetReplica;

PRINT N'-- Run on ' + @TargetReplica + N' (the new primary), not on the current primary:';
PRINT N'ALTER AVAILABILITY GROUP ' + QUOTENAME(@AGName) + N' FAILOVER;';
PRINT N'-- Never use FORCE_FAILOVER_ALLOW_DATA_LOSS for a planned failover.';
