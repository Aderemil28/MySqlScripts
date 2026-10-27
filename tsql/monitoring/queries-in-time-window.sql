/*
Script  : queries-in-time-window.sql
Purpose : "What was running against this database between 10:00 and 11:15?"
          Cached statements for one database whose last execution falls in a
          time window, with execution count, duration, CPU and reads. Use it
          after an incident, a slow period, or an alert from monitoring.
Usage   : Set @DatabaseName, @From and @To, then run. Times are server local time.
Changes : Read-only.
Requires: SQL Server 2016 and later. VIEW SERVER STATE.
Limits  : The plan cache only keeps the LAST execution time of each statement,
          and plans can be evicted (restart, memory pressure, recompiles). A
          statement that ran in the window and again afterwards will not show.
          For reliable history, use Query Store (sys.query_store_runtime_stats)
          or your monitoring tool's history.
Fixes vs the original notes:
          - filtered on sys.dm_exec_sql_text.dbid, which is NULL for ad hoc and
            prepared statements (most application queries), so they were
            missed; the database now comes from the plan's dbid attribute
          - the database name and dates were hard-coded; now variables
          - added averages, CPU and the plan handle for drilling in
*/
SET NOCOUNT ON;

DECLARE @DatabaseName sysname  = N'AppDB';
DECLARE @From         datetime = '2026-07-14 10:00:00';
DECLARE @To           datetime = '2026-07-14 11:15:00';

SELECT  qs.last_execution_time,
        qs.execution_count,
        qs.total_elapsed_time / 1000                                    AS total_elapsed_ms,
        qs.total_elapsed_time / NULLIF(qs.execution_count, 0) / 1000    AS avg_elapsed_ms,
        qs.total_worker_time  / NULLIF(qs.execution_count, 0) / 1000    AS avg_cpu_ms,
        qs.total_logical_reads,
        qs.total_logical_reads / NULLIF(qs.execution_count, 0)          AS avg_logical_reads,
        OBJECT_NAME(st.objectid, pa.dbid)                               AS object_name,
        SUBSTRING(st.text, (qs.statement_start_offset / 2) + 1,
                  ((CASE qs.statement_end_offset
                         WHEN -1 THEN DATALENGTH(st.text)
                         ELSE qs.statement_end_offset END
                    - qs.statement_start_offset) / 2) + 1)              AS statement_text,
        qs.plan_handle
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
CROSS APPLY (SELECT CAST(a.value AS int) AS dbid
             FROM sys.dm_exec_plan_attributes(qs.plan_handle) AS a
             WHERE a.attribute = N'dbid') AS pa
WHERE qs.last_execution_time BETWEEN @From AND @To
  AND pa.dbid = DB_ID(@DatabaseName)
ORDER BY qs.last_execution_time DESC;

-- To see the plan for one row:
-- SELECT query_plan FROM sys.dm_exec_query_plan(<plan_handle>);
