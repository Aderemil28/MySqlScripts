/*
Script  : shrink-log-files.sql
Purpose : Creates dbo.usp_ShrinkLogFiles, which shrinks transaction log files for
          one database or all user databases to a target size, and reports the
          size before and after.
Usage   : Shrinking logs should be a one-off fix after an unusual event (a huge
          index rebuild, a stuck log backup), not routine maintenance. Fix the
          cause first (see log-space-and-reuse-wait.sql), take a log backup, then:
              EXEC dbo.usp_ShrinkLogFiles @DatabaseName = N'AppDB', @TargetMB = 4096;            -- preview
              EXEC dbo.usp_ShrinkLogFiles @DatabaseName = N'AppDB', @TargetMB = 4096, @Execute = 1;
          @DatabaseName = N'%' targets every user database.
Changes : Creates a procedure in master. Shrinks log files when @Execute = 1.
Requires: SQL Server 2016 SP1 and later (CREATE OR ALTER).
Fixes vs the original notes:
          - preview by default, target size instead of "as small as possible"
            (shrinking to zero just forces the log to autogrow again)
          - skips databases that are read-only or not ONLINE
*/
USE [master];
GO

CREATE OR ALTER PROCEDURE dbo.usp_ShrinkLogFiles
    @DatabaseName sysname = N'%',
    @TargetMB     int     = 1024,
    @Execute      bit     = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @cmd nvarchar(max) = N'';

    IF OBJECT_ID(N'tempdb..#before') IS NOT NULL DROP TABLE #before;
    SELECT d.database_id, d.name AS database_name, f.name AS log_file, f.size / 128 AS size_mb_before
    INTO #before
    FROM sys.databases AS d
    JOIN sys.master_files AS f ON f.database_id = d.database_id AND f.type = 1
    WHERE d.database_id > 4
      AND d.state_desc = N'ONLINE'
      AND d.is_read_only = 0
      AND d.name LIKE @DatabaseName;

    SELECT @cmd += N'USE ' + QUOTENAME(database_name) + N'; CHECKPOINT; DBCC SHRINKFILE (N'''
                 + REPLACE(log_file, N'''', N'''''') + N''', ' + CAST(@TargetMB AS nvarchar(10)) + N') WITH NO_INFOMSGS;'
                 + CHAR(13) + CHAR(10)
    FROM #before
    WHERE size_mb_before > @TargetMB;

    PRINT @cmd;
    IF @Execute = 1 AND @cmd <> N'' EXEC (@cmd);

    SELECT b.database_name, b.log_file, b.size_mb_before, f.size / 128 AS size_mb_after
    FROM #before AS b
    JOIN sys.master_files AS f ON f.database_id = b.database_id AND f.name = b.log_file
    ORDER BY b.database_name;
END;
GO
