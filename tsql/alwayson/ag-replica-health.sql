/*
Script  : ag-replica-health.sql
Purpose : One-row-per-database health view of every availability group visible
          from this replica: role, sync state and health, queues, last commit,
          listener and backup priority.
Usage   : Run on the primary for the full picture. On a secondary you only see
          that replica's local database states.
Changes : Read-only.
Requires: SQL Server 2016 and later.
Notes   : log_send_queue_size and redo_queue_size are in KB.
          secondary_lag_seconds (2016+) is the best single "how far behind" number.
*/
SELECT
    ag.name                              AS ag_name,
    agl.dns_name                         AS listener_name,
    ar.replica_server_name,
    ars.role_desc,
    ars.connected_state_desc,
    ar.availability_mode_desc,
    ar.failover_mode_desc,
    DB_NAME(drs.database_id)             AS database_name,
    drs.synchronization_state_desc,
    drs.synchronization_health_desc,
    drs.is_suspended,
    drs.suspend_reason_desc,
    drs.log_send_queue_size              AS log_send_queue_kb,
    drs.log_send_rate                    AS log_send_rate_kb_sec,
    drs.redo_queue_size                  AS redo_queue_kb,
    drs.redo_rate                        AS redo_rate_kb_sec,
    drs.secondary_lag_seconds,
    drs.last_hardened_lsn,
    drs.last_commit_lsn,
    drs.last_commit_time,
    ar.backup_priority
FROM sys.availability_groups AS ag
JOIN sys.availability_replicas AS ar
     ON ar.group_id = ag.group_id
JOIN sys.dm_hadr_availability_replica_states AS ars
     ON ars.replica_id = ar.replica_id
LEFT JOIN sys.dm_hadr_database_replica_states AS drs
     ON drs.replica_id = ar.replica_id
LEFT JOIN sys.availability_group_listeners AS agl
     ON agl.group_id = ag.group_id
ORDER BY ag.name, database_name, ars.role_desc, ar.replica_server_name;
