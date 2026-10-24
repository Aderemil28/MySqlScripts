/*
Script  : ag-sync-lag.sql
Purpose : Estimated data loss per database and secondary, in seconds, by
          comparing the primary's last commit time with each secondary's.
          Large numbers on an asynchronous replica are what you would lose in
          a forced failover right now.
Usage   : Run on the primary replica.
Changes : Read-only.
Requires: SQL Server 2016 and later.
*/
WITH ag_stats AS
(
    SELECT
        ag.name                      AS ag_name,
        ar.replica_server_name,
        ars.role_desc,
        drs.database_id,
        drs.last_commit_time
    FROM sys.dm_hadr_database_replica_states AS drs
    JOIN sys.availability_replicas AS ar  ON ar.replica_id = drs.replica_id
    JOIN sys.availability_groups   AS ag  ON ag.group_id   = ar.group_id
    JOIN sys.dm_hadr_availability_replica_states AS ars ON ars.replica_id = ar.replica_id
)
SELECT
    p.ag_name,
    DB_NAME(p.database_id)      AS database_name,
    p.replica_server_name       AS primary_replica,
    s.replica_server_name       AS secondary_replica,
    p.last_commit_time          AS primary_last_commit,
    s.last_commit_time          AS secondary_last_commit,
    DATEDIFF(SECOND, s.last_commit_time, p.last_commit_time) AS estimated_data_loss_sec
FROM ag_stats AS p
JOIN ag_stats AS s
  ON s.ag_name = p.ag_name
 AND s.database_id = p.database_id
 AND s.role_desc = 'SECONDARY'
WHERE p.role_desc = 'PRIMARY'
ORDER BY estimated_data_loss_sec DESC;
