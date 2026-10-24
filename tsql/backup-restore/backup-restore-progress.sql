/*
Script  : backup-restore-progress.sql
Purpose : Progress and estimated finish time for running BACKUP, RESTORE and
          DBCC operations (anything that reports percent_complete).
Usage   : Run while the operation is in progress. Re-run to refresh.
Changes : Read-only.
Requires: SQL Server 2016 and later.
*/
SELECT
    r.session_id,
    r.command,
    DB_NAME(r.database_id)                                       AS database_name,
    CAST(r.percent_complete AS decimal(5,2))                     AS percent_complete,
    r.start_time,
    CAST(r.total_elapsed_time / 60000.0 AS decimal(10,1))        AS elapsed_min,
    CAST(r.estimated_completion_time / 60000.0 AS decimal(10,1)) AS remaining_min,
    DATEADD(MILLISECOND, r.estimated_completion_time, GETDATE()) AS estimated_finish,
    r.wait_type,
    r.blocking_session_id
FROM sys.dm_exec_requests AS r
WHERE r.command LIKE N'BACKUP%'
   OR r.command LIKE N'RESTORE%'
   OR r.command LIKE N'DBCC%'
ORDER BY r.start_time;
