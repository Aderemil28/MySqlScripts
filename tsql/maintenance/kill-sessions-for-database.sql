/*
Script  : kill-sessions-for-database.sql
Purpose : Clears all user connections from a database before a restore, rename,
          or taking it offline.
          Option A (preferred): SINGLE_USER WITH ROLLBACK IMMEDIATE, which
          disconnects everyone and stops new connections in one step.
          Option B: KILL each user session connected to the database.
Usage   : Set @DatabaseName and @Execute. Check who is connected first with
          tsql/monitoring/sessions-by-database-host-or-program.sql.
          Not for AG databases: SINGLE_USER is not allowed there, and you
          normally fail over or remove the database from the AG instead.
Changes : Disconnects sessions (open transactions roll back) when @Execute = 1.
Requires: SQL Server 2016 and later.
*/
SET NOCOUNT ON;

DECLARE @DatabaseName sysname = N'YourDatabaseName';
DECLARE @Execute      bit     = 0;

-- Option A
DECLARE @sqlA nvarchar(max) =
      N'ALTER DATABASE ' + QUOTENAME(@DatabaseName) + N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE;' + CHAR(13) + CHAR(10)
    + N'-- ... do the restore / rename / offline here ...' + CHAR(13) + CHAR(10)
    + N'-- ALTER DATABASE ' + QUOTENAME(@DatabaseName) + N' SET MULTI_USER;';
PRINT N'-- Option A:';
PRINT @sqlA;

-- Option B
DECLARE @sqlB nvarchar(max) = N'';
SELECT @sqlB += N'KILL ' + CAST(session_id AS nvarchar(10)) + N';' + CHAR(13) + CHAR(10)
FROM sys.dm_exec_sessions
WHERE database_id = DB_ID(@DatabaseName)
  AND is_user_process = 1
  AND session_id <> @@SPID;

PRINT N'-- Option B:';
PRINT ISNULL(NULLIF(@sqlB, N''), N'-- no user sessions connected');

IF @Execute = 1 AND @sqlB <> N''
    EXEC sys.sp_executesql @sqlB;
