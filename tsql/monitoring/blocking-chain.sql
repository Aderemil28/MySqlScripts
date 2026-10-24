/*
Script  : blocking-chain.sql
Purpose : Shows current blocking: lead blockers first, then every blocked
          request with what it waits on and the SQL text on both sides.
          A lightweight alternative when sp_WhoIsActive is not installed.
Usage   : Run while the blocking is happening.
Changes : Read-only.
Requires: SQL Server 2016 and later.
*/

-- 1. Lead blockers (blocking others, not blocked themselves)
SELECT
    s.session_id                    AS lead_blocker,
    s.login_name,
    s.host_name,
    s.program_name,
    DB_NAME(s.database_id)          AS database_name,
    s.status,
    s.open_transaction_count,
    s.last_request_end_time,
    (SELECT COUNT(*) FROM sys.dm_exec_requests AS r2 WHERE r2.blocking_session_id = s.session_id) AS directly_blocked,
    t.text                          AS last_sql
FROM sys.dm_exec_sessions AS s
LEFT JOIN sys.dm_exec_requests AS r ON r.session_id = s.session_id
LEFT JOIN sys.dm_exec_connections AS c ON c.session_id = s.session_id
OUTER APPLY sys.dm_exec_sql_text(c.most_recent_sql_handle) AS t
WHERE EXISTS (SELECT 1 FROM sys.dm_exec_requests AS b WHERE b.blocking_session_id = s.session_id)
  AND ISNULL(r.blocking_session_id, 0) = 0;

-- 2. Every blocked request
SELECT
    r.session_id,
    r.blocking_session_id,
    r.wait_type,
    r.wait_time / 1000.0            AS wait_sec,
    r.wait_resource,
    DB_NAME(r.database_id)          AS database_name,
    s.login_name,
    s.host_name,
    s.program_name,
    SUBSTRING(t.text, r.statement_start_offset / 2 + 1,
        (CASE r.statement_end_offset WHEN -1 THEN DATALENGTH(t.text) ELSE r.statement_end_offset END
         - r.statement_start_offset) / 2 + 1) AS running_statement
FROM sys.dm_exec_requests AS r
JOIN sys.dm_exec_sessions AS s ON s.session_id = r.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE r.blocking_session_id <> 0
ORDER BY r.wait_time DESC;
