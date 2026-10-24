/*
Script  : drop-login-with-active-sessions.sql
Purpose : Drops a login that fails with "Could not drop login as the user is
          currently logged in". Lists the login's sessions, optionally kills
          them, then drops the login.
Usage   : Set @LoginName. Run with @Execute = 0 to see the sessions and the
          commands. Set @Execute = 1 to kill the sessions and drop the login.
          Database users mapped to the login are not dropped; they become
          orphaned (see orphaned-users-find.sql).
Changes : Kills sessions and drops the login when @Execute = 1.
Requires: SQL Server 2016 and later.
Source  : Idea from a SQLAuthority post (2012), rewritten with guardrails.
*/
SET NOCOUNT ON;

DECLARE @LoginName sysname = N'LoginToRemove';
DECLARE @Execute   bit     = 0;

SELECT session_id, login_name, host_name, program_name, status, login_time, last_request_end_time
FROM sys.dm_exec_sessions
WHERE login_name = @LoginName;

DECLARE @sql nvarchar(max) = N'';

SELECT @sql += N'KILL ' + CAST(session_id AS nvarchar(10)) + N'; '
FROM sys.dm_exec_sessions
WHERE login_name = @LoginName
  AND session_id <> @@SPID;

SET @sql += N'DROP LOGIN ' + QUOTENAME(@LoginName) + N';';

PRINT @sql;
IF @Execute = 1 EXEC sys.sp_executesql @sql;
