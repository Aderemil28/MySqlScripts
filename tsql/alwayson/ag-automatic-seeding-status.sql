/*
Script  : ag-automatic-seeding-status.sql
Purpose : Progress and history of automatic seeding when a database is added to
          an availability group with SEEDING_MODE = AUTOMATIC.
            1. Seeding history and failures
            2. Live progress of a seed that is running now
Usage   : Run on the primary (and the secondary for section 2 if needed).
Changes : Read-only.
Requires: SQL Server 2016 and later.
*/

-- 1. Seeding history
SELECT
    ag.name AS ag_name,
    s.start_time,
    s.completion_time,
    s.is_source,
    s.current_state,
    s.failure_state,
    s.failure_state_desc,
    s.number_of_attempts,
    s.error_code
FROM sys.dm_hadr_automatic_seeding AS s
JOIN sys.availability_groups AS ag ON ag.group_id = s.ag_id
ORDER BY s.start_time DESC;

-- 2. Seeds running now
SELECT
    local_database_name,
    remote_machine_name,
    role_desc,
    internal_state_desc,
    transferred_size_bytes / 1048576  AS transferred_mb,
    database_size_bytes / 1048576     AS database_mb,
    CAST(100.0 * transferred_size_bytes / NULLIF(database_size_bytes, 0) AS decimal(5,2)) AS percent_done,
    estimate_time_complete_utc,
    failure_message
FROM sys.dm_hadr_physical_seeding_stats;
