/*
Script  : drive-usage-db-files-vs-other.sql
Purpose : For every drive that holds a database file: total, used and free
          space, how much of it the database files take, and how much is used
          by something else (backups, logs, other applications). Answers "is
          it SQL Server filling this drive, or something else?" Then lists
          every file with its free space and a ready-made resize command.
Usage   : Run as is. Set @DatabaseName to limit section 2 to one database, and
          @Drive (for example N'E:\') to limit it to one drive.
          Databases that can't be read (offline, restoring, no access) are
          listed in section 3 instead of stopping the script.
Changes : Read-only. Section 2 only prints resize commands; nothing runs.
Requires: SQL Server 2016 and later.
Fixes vs the original notes:
          - growth in MB was growth * 8 / 1024 with integer maths (a 64 MB
            growth showed 0 when growth < 128 pages); now growth / 128.0
          - grouping by LEFT(physical_name, 3) broke on mount points; now
            grouped by the real volume from sys.dm_os_volume_stats
          - the resize command was built with [ ] around the name; now QUOTENAME
*/
SET NOCOUNT ON;

DECLARE @DatabaseName sysname       = NULL;   -- NULL = all databases
DECLARE @Drive        nvarchar(260) = NULL;   -- NULL = all drives, or for example N'E:\'

IF OBJECT_ID(N'tempdb..#files')   IS NOT NULL DROP TABLE #files;
IF OBJECT_ID(N'tempdb..#skipped') IS NOT NULL DROP TABLE #skipped;
CREATE TABLE #files
(
    database_name sysname, file_id int, logical_name sysname, type_desc nvarchar(60),
    physical_name nvarchar(260), filegroup_name sysname NULL,
    size_mb decimal(18,2), used_mb decimal(18,2), growth_setting nvarchar(40)
);
CREATE TABLE #skipped (database_name sysname, error_message nvarchar(4000), skipped_at datetime2(0));

DECLARE @inner nvarchar(max) = N'
INSERT INTO #files
SELECT DB_NAME(), df.file_id, df.name, df.type_desc, df.physical_name, ds.name,
       df.size / 128.0,
       CAST(FILEPROPERTY(df.name, ''SpaceUsed'') AS bigint) / 128.0,
       CASE WHEN df.is_percent_growth = 1 THEN CAST(df.growth AS varchar(10)) + '' %''
            ELSE CAST(CAST(df.growth / 128.0 AS decimal(18,0)) AS varchar(20)) + '' MB'' END
FROM sys.database_files AS df
LEFT JOIN sys.data_spaces AS ds ON ds.data_space_id = df.data_space_id;';

DECLARE @db sysname, @proc nvarchar(300);
DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases WHERE state_desc = N'ONLINE' ORDER BY name;
OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @db;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @proc = QUOTENAME(@db) + N'.sys.sp_executesql';
    BEGIN TRY
        EXEC @proc @inner;
    END TRY
    BEGIN CATCH
        INSERT INTO #skipped VALUES (@db, ERROR_MESSAGE(), SYSDATETIME());
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @db;
END;
CLOSE db_cursor;
DEALLOCATE db_cursor;

-- 1. Each drive: database files versus everything else
WITH file_volume AS
(
    SELECT f.size_mb, f.used_mb,
           vs.volume_mount_point, vs.logical_volume_name,
           vs.total_bytes, vs.available_bytes
    FROM #files AS f
    JOIN sys.master_files AS mf ON mf.database_id = DB_ID(f.database_name) AND mf.file_id = f.file_id
    CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) AS vs
),
drive AS
(
    SELECT volume_mount_point, logical_volume_name,
           MAX(total_bytes) / 1048576.0                          AS total_mb,
           MAX(available_bytes) / 1048576.0                      AS free_mb,
           (MAX(total_bytes) - MAX(available_bytes)) / 1048576.0 AS used_mb,
           SUM(size_mb)                                          AS db_files_mb,
           SUM(used_mb)                                          AS db_files_used_mb
    FROM file_volume
    GROUP BY volume_mount_point, logical_volume_name
)
SELECT  @@SERVERNAME                                                   AS server_name,
        volume_mount_point                                             AS drive,
        logical_volume_name                                            AS label,
        CAST(total_mb AS decimal(18,0))                                AS total_mb,
        CAST(used_mb  AS decimal(18,0))                                AS used_mb,
        CAST(free_mb  AS decimal(18,0))                                AS free_mb,
        CAST(free_mb * 100.0 / NULLIF(total_mb, 0) AS decimal(5,2))    AS free_pct,
        CAST(db_files_mb AS decimal(18,0))                             AS db_files_mb,
        CAST(db_files_mb * 100.0 / NULLIF(total_mb, 0) AS decimal(5,2)) AS db_files_pct,
        CAST(db_files_mb - db_files_used_mb AS decimal(18,0))          AS free_inside_db_files_mb,
        CAST(used_mb - db_files_mb AS decimal(18,0))                   AS used_by_others_mb,
        CAST((used_mb - db_files_mb) * 100.0 / NULLIF(total_mb, 0) AS decimal(5,2)) AS used_by_others_pct
FROM drive
ORDER BY volume_mount_point;

-- 2. Every file, with a resize command you can copy (prints only)
SELECT  f.database_name,
        f.logical_name,
        f.type_desc,
        f.filegroup_name,
        vs.volume_mount_point                                          AS drive,
        CAST(f.size_mb AS decimal(18,0))                               AS size_mb,
        CAST(f.used_mb AS decimal(18,0))                               AS used_mb,
        CAST(f.size_mb - f.used_mb AS decimal(18,0))                   AS free_mb,
        CAST(f.used_mb * 100.0 / NULLIF(f.size_mb, 0) AS decimal(5,2)) AS used_pct,
        f.growth_setting,
        N'ALTER DATABASE ' + QUOTENAME(f.database_name) + N' MODIFY FILE (NAME = ' + QUOTENAME(f.logical_name, '''')
            + N', SIZE = ' + CAST(CAST(f.size_mb AS bigint) AS nvarchar(20)) + N'MB);' AS resize_command_current_size,
        f.physical_name
FROM #files AS f
JOIN sys.master_files AS mf ON mf.database_id = DB_ID(f.database_name) AND mf.file_id = f.file_id
CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) AS vs
WHERE (@DatabaseName IS NULL OR f.database_name = @DatabaseName)
  AND (@Drive IS NULL OR vs.volume_mount_point = @Drive)
ORDER BY f.database_name, f.size_mb DESC;

-- 3. Databases that could not be read
SELECT database_name, error_message, skipped_at FROM #skipped;

DROP TABLE #files;
DROP TABLE #skipped;
