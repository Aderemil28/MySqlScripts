/*
Script  : sessions-by-database-host-or-program.sql
Purpose : Who is connected to a database, from which host and application.
          Use before taking a database offline, restoring over it, or when
          confirming an application tier is really stopped (for example an
          installer or web console still holding connections).
Usage   : Set any of the filters (NULL = ignore). LIKE wildcards are allowed.
          Tip: installer and health-check connections are short-lived, so run
          this right after the client retries.
Changes : Read-only.
Requires: SQL Server 2016 and later.
*/
DECLARE @DatabaseName sysname       = NULL;   -- for example N'AppDB'
DECLARE @HostLike     nvarchar(128) = NULL;   -- client machine name, for example N'APPSRV%'
DECLARE @ProgramLike  nvarchar(128) = NULL;   -- for example N'%JDBC%' or N'PHP%'
DECLARE @LoginLike    nvarchar(128) = NULL;

SELECT
    s.session_id,
    DB_NAME(s.database_id)   AS database_name,
    s.login_name,
    s.host_name,             -- client machine, not the login
    s.program_name,
    s.status,
    r.command,
    r.wait_type,
    r.blocking_session_id,
    c.client_net_address,
    s.login_time,
    s.last_request_end_time,
    s.open_transaction_count
FROM sys.dm_exec_sessions AS s
LEFT JOIN sys.dm_exec_connections AS c ON c.session_id = s.session_id
LEFT JOIN sys.dm_exec_requests    AS r ON r.session_id = s.session_id
WHERE s.is_user_process = 1
  AND s.session_id <> @@SPID
  AND (@DatabaseName IS NULL OR s.database_id = DB_ID(@DatabaseName))
  AND (@HostLike     IS NULL OR s.host_name    LIKE @HostLike)
  AND (@ProgramLike  IS NULL OR s.program_name LIKE @ProgramLike)
  AND (@LoginLike    IS NULL OR s.login_name   LIKE @LoginLike)
ORDER BY database_name, s.host_name, s.program_name;
