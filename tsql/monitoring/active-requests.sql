/*
Script  : active-requests.sql
Purpose : Everything running right now, heaviest first: who, from where, how
          long, waits, CPU, reads and writes, memory grant, blocking (both
          directions), the running statement and its plan. A lightweight
          sp_WhoIsActive alternative for servers where it isn't installed.
Usage   : Run as is. Click the query_plan value in SSMS to open the plan.
          Set @IncludePlans = 0 on a very busy server: fetching plans adds load.
Changes : Read-only.
Requires: SQL Server 2016 and later. VIEW SERVER STATE.
Fixes vs the original notes:
          - CROSS APPLY to the SQL text and plan dropped requests that had
            none (background work, some waits); now OUTER APPLY
          - the statement extraction started one character late
          - the WITH (NOLOCK) hint on a DMV did nothing; removed
          - the "score" (cpu x weighted I/O) is kept for ordering, and
            explained below
*/
SET NOCOUNT ON;

DECLARE @IncludePlans bit = 1;

SELECT
    r.session_id,
    s.status,
    r.command,
    DB_NAME(r.database_id)                                   AS database_name,
    s.login_name,
    s.host_name,
    s.program_name,
    s.client_interface_name,
    r.start_time,
    CAST(r.total_elapsed_time / 1000.0 AS decimal(18,1))     AS elapsed_sec,
    r.percent_complete,
    r.blocking_session_id                                    AS blocked_by,
    ISNULL(b.blocked_count, 0)                               AS is_blocking_count,
    r.wait_type,
    r.wait_time                                              AS wait_ms,
    r.cpu_time                                               AS cpu_ms,
    r.reads,
    r.writes,
    r.logical_reads,
    t.pending_io_count,
    r.row_count,
    r.granted_query_memory * 8                               AS granted_memory_kb,
    r.dop,
    -- Heaviness score used for ordering: CPU multiplied by I/O,
    -- with physical reads and writes weighted 10x over logical reads
    CONVERT(bigint, r.cpu_time + 1)
        * CONVERT(bigint, r.reads * 10 + r.writes * 10 + r.logical_reads + 1) AS score,
    CASE WHEN st.text IS NULL THEN NULL
         ELSE SUBSTRING(st.text, r.statement_start_offset / 2 + 1,
                (CASE r.statement_end_offset WHEN -1 THEN DATALENGTH(st.text)
                      ELSE r.statement_end_offset END - r.statement_start_offset) / 2 + 1)
    END                                                      AS running_statement,
    st.text                                                  AS batch_text,
    CASE WHEN @IncludePlans = 1 THEN qp.query_plan END       AS query_plan
FROM sys.dm_exec_requests AS r
JOIN sys.dm_exec_sessions AS s ON s.session_id = r.session_id
LEFT JOIN (SELECT blocking_session_id, COUNT(*) AS blocked_count
           FROM sys.dm_exec_requests
           WHERE blocking_session_id <> 0
           GROUP BY blocking_session_id) AS b ON b.blocking_session_id = r.session_id
LEFT JOIN (SELECT session_id, request_id, SUM(pending_io_count) AS pending_io_count
           FROM sys.dm_os_tasks
           GROUP BY session_id, request_id) AS t
       ON t.session_id = r.session_id AND t.request_id = r.request_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS st
OUTER APPLY (SELECT query_plan FROM sys.dm_exec_query_plan(r.plan_handle) WHERE @IncludePlans = 1) AS qp
WHERE s.is_user_process = 1
  AND r.session_id <> @@SPID
ORDER BY score DESC;
