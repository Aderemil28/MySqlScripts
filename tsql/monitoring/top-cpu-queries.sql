/*
Script  : top-cpu-queries.sql
Purpose : The cached queries that have used the most CPU since they entered the
          plan cache, with average CPU, duration, reads and the statement text.
          Focus on the top 3 to 5; that is usually where the real gain is.
Usage   : Run as is. Change ORDER BY to avg_cpu_ms to find the most expensive
          single executions instead of the biggest total consumers.
          Only covers plans still in cache; a restart or memory pressure clears it.
          Query Store (if enabled) keeps longer history.
Changes : Read-only.
Requires: SQL Server 2016 and later.
Fixes vs the original notes: '#' comments are not valid T-SQL, AvgCPU was in
          microseconds while labelled with CPU in ms, and the statement
          extraction cut off the first character.
*/
SELECT TOP (20)
    CAST(qs.total_worker_time / 1000.0 AS decimal(18,1))                         AS total_cpu_ms,
    qs.execution_count,
    CAST(qs.total_worker_time / 1000.0 / qs.execution_count AS decimal(18,2))    AS avg_cpu_ms,
    CAST(qs.total_elapsed_time / 1000.0 / qs.execution_count AS decimal(18,2))   AS avg_duration_ms,
    qs.total_logical_reads / qs.execution_count                                  AS avg_logical_reads,
    qs.last_execution_time,
    DB_NAME(qt.dbid)                                                             AS database_name,
    OBJECT_NAME(qt.objectid, qt.dbid)                                            AS object_name,
    SUBSTRING(qt.text, qs.statement_start_offset / 2 + 1,
        (CASE WHEN qs.statement_end_offset = -1 THEN DATALENGTH(qt.text)
              ELSE qs.statement_end_offset END - qs.statement_start_offset) / 2 + 1) AS statement_text,
    qp.query_plan
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS qt
OUTER APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
ORDER BY qs.total_worker_time DESC;
