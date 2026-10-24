/*
Script  : pre-grow-data-files.sql
Purpose : Pre-grows data files by a percentage of their current size during a
          change window, so the database does not autogrow under load.
          Produces BEFORE evidence (current size, growth amount, target size,
          drive free space before and after), then the ALTER DATABASE commands,
          then AFTER evidence.
Usage   : 1. Set @DatabaseName (or NULL for every database whose data files are
             above @MinPctUsed), @GrowPct, and @MinDriveFreePct.
          2. Run with @Execute = 0 and screenshot the BEFORE result for the change record.
          3. Set @Execute = 1 and run again. The AFTER result is the evidence.
          On an availability group, run on the PRIMARY. The size change is
          replayed on secondaries automatically, but check their drives have
          room first, because a secondary that cannot grow the file stops
          synchronizing. ALTER DATABASE fails on a readable secondary with
          "database must be in a writable state".
Changes : Grows data files when @Execute = 1. Growing a file cannot be undone
          without a shrink, so confirm the numbers first.
Requires: SQL Server 2016 and later.
*/
SET NOCOUNT ON;

DECLARE @DatabaseName    sysname       = N'YourDatabaseName';  -- NULL = all databases matching @MinPctUsed
DECLARE @GrowPct         decimal(5,2)  = 10.0;                 -- grow by this % of current size
DECLARE @MinPctUsed      decimal(5,2)  = 75.0;                 -- only used when @DatabaseName IS NULL
DECLARE @MinDriveFreePct decimal(5,2)  = 10.0;                 -- refuse if the drive would drop below this % free
DECLARE @Execute         bit           = 0;

IF OBJECT_ID(N'tempdb..#plan') IS NOT NULL DROP TABLE #plan;
CREATE TABLE #plan
(
    database_name sysname, logical_name sysname, physical_name nvarchar(260),
    current_mb bigint, used_mb bigint, grow_mb bigint, target_mb bigint,
    drive nvarchar(260), drive_free_mb bigint, drive_total_mb bigint
);

DECLARE @inner nvarchar(max) = N'
INSERT INTO #plan (database_name, logical_name, physical_name, current_mb, used_mb)
SELECT DB_NAME(), name, physical_name, size / 128, CAST(FILEPROPERTY(name, ''SpaceUsed'') AS bigint) / 128
FROM sys.database_files
WHERE type = 0;';

DECLARE @db sysname, @proc nvarchar(300);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases
    WHERE state_desc = N'ONLINE' AND database_id > 4
      AND (@DatabaseName IS NULL OR name = @DatabaseName)
      AND DATABASEPROPERTYEX(name, 'Updateability') = 'READ_WRITE';
OPEN c;
FETCH NEXT FROM c INTO @db;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @proc = QUOTENAME(@db) + N'.sys.sp_executesql';
    EXEC @proc @inner;
    FETCH NEXT FROM c INTO @db;
END;
CLOSE c;
DEALLOCATE c;

IF @DatabaseName IS NULL
    DELETE FROM #plan WHERE used_mb * 100.0 / NULLIF(current_mb, 0) < @MinPctUsed;

UPDATE p
SET grow_mb        = CAST(p.current_mb * @GrowPct / 100 AS bigint),
    target_mb      = p.current_mb + CAST(p.current_mb * @GrowPct / 100 AS bigint),
    drive          = vs.volume_mount_point,
    drive_free_mb  = vs.available_bytes / 1048576,
    drive_total_mb = vs.total_bytes / 1048576
FROM #plan AS p
JOIN sys.master_files AS mf ON mf.database_id = DB_ID(p.database_name) AND mf.name = p.logical_name
CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) AS vs;

-- BEFORE evidence
SELECT
    @@SERVERNAME AS server_name, GETDATE() AS captured_at, 'BEFORE' AS stage,
    database_name, logical_name, current_mb, used_mb,
    CAST(used_mb * 100.0 / NULLIF(current_mb, 0) AS decimal(5,2))   AS pct_used,
    grow_mb, target_mb, drive,
    drive_free_mb                                                   AS drive_free_mb_before,
    drive_free_mb - grow_mb                                         AS drive_free_mb_after,
    CAST((drive_free_mb - grow_mb) * 100.0 / NULLIF(drive_total_mb, 0) AS decimal(5,2)) AS drive_free_pct_after,
    CASE WHEN (drive_free_mb - grow_mb) * 100.0 / NULLIF(drive_total_mb, 0) < @MinDriveFreePct
         THEN 'SKIP - not enough drive space' ELSE 'OK' END          AS check_result
FROM #plan
ORDER BY database_name, logical_name;

-- Commands (only files that pass the drive check)
DECLARE @sql nvarchar(max), @dbn sysname, @lname sysname, @target bigint;
DECLARE g CURSOR LOCAL FAST_FORWARD FOR
    SELECT database_name, logical_name, target_mb
    FROM #plan
    WHERE (drive_free_mb - grow_mb) * 100.0 / NULLIF(drive_total_mb, 0) >= @MinDriveFreePct;
OPEN g;
FETCH NEXT FROM g INTO @dbn, @lname, @target;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'ALTER DATABASE ' + QUOTENAME(@dbn) + N' MODIFY FILE (NAME = N''' + REPLACE(@lname, N'''', N'''''')
             + N''', SIZE = ' + CAST(@target AS nvarchar(20)) + N'MB);';
    PRINT @sql;
    IF @Execute = 1
    BEGIN
        BEGIN TRY EXEC sys.sp_executesql @sql; END TRY
        BEGIN CATCH PRINT N'   FAILED: ' + ERROR_MESSAGE(); END CATCH;
    END;
    FETCH NEXT FROM g INTO @dbn, @lname, @target;
END;
CLOSE g;
DEALLOCATE g;

-- AFTER evidence
IF @Execute = 1
    SELECT
        @@SERVERNAME AS server_name, GETDATE() AS captured_at, 'AFTER' AS stage,
        p.database_name, p.logical_name, p.current_mb AS size_mb_before, mf.size / 128 AS size_mb_after,
        p.target_mb, CASE WHEN mf.size / 128 >= p.target_mb THEN 'OK' ELSE 'CHECK' END AS result,
        vs.volume_mount_point AS drive, vs.available_bytes / 1048576 AS drive_free_mb_now
    FROM #plan AS p
    JOIN sys.master_files AS mf ON mf.database_id = DB_ID(p.database_name) AND mf.name = p.logical_name
    CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) AS vs
    ORDER BY p.database_name, p.logical_name;

DROP TABLE #plan;
