/*
Script  : database-file-sizes-and-free-space.sql
Purpose : Size, used space, free space and % used for every data and log file in
          every online database, with growth settings and the drive's free
          space. Sort by pct_used to find files that need pre-growth.
Usage   : Run as is. Change @PctUsedAlert to highlight files above a threshold.
Changes : Read-only.
Requires: SQL Server 2016 and later.
*/
SET NOCOUNT ON;

DECLARE @PctUsedAlert decimal(5,2) = 85.0;

IF OBJECT_ID(N'tempdb..#files') IS NOT NULL DROP TABLE #files;
CREATE TABLE #files
(
    database_name sysname, file_id int, logical_name sysname, type_desc nvarchar(60),
    physical_name nvarchar(260), size_mb decimal(18,2), used_mb decimal(18,2),
    is_percent_growth bit, growth int, max_size int
);

DECLARE @inner nvarchar(max) = N'
INSERT INTO #files
SELECT DB_NAME(), file_id, name, type_desc, physical_name,
       size / 128.0,
       CAST(FILEPROPERTY(name, ''SpaceUsed'') AS int) / 128.0,
       is_percent_growth, growth, max_size
FROM sys.database_files
WHERE type IN (0, 1);';

DECLARE @db sysname, @proc nvarchar(300);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases WHERE state_desc = N'ONLINE' ORDER BY name;
OPEN c;
FETCH NEXT FROM c INTO @db;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @proc = QUOTENAME(@db) + N'.sys.sp_executesql';
    BEGIN TRY EXEC @proc @inner; END TRY BEGIN CATCH PRINT @db + N': ' + ERROR_MESSAGE(); END CATCH;
    FETCH NEXT FROM c INTO @db;
END;
CLOSE c;
DEALLOCATE c;

SELECT
    f.database_name,
    f.logical_name,
    f.type_desc,
    f.size_mb,
    f.used_mb,
    f.size_mb - f.used_mb                                         AS free_mb,
    CAST(f.used_mb * 100.0 / NULLIF(f.size_mb, 0) AS decimal(5,2)) AS pct_used,
    CASE WHEN f.used_mb * 100.0 / NULLIF(f.size_mb, 0) >= @PctUsedAlert THEN '<<' ELSE '' END AS alert,
    CASE WHEN f.is_percent_growth = 1 THEN CAST(f.growth AS varchar(10)) + ' %'
         ELSE CAST(f.growth / 128 AS varchar(10)) + ' MB' END     AS growth_setting,
    CASE WHEN f.max_size = -1 THEN 'Unlimited'
         WHEN f.max_size = 268435456 THEN 'Unlimited (2 TB log cap)'
         ELSE CAST(f.max_size / 128 AS varchar(20)) + ' MB' END    AS max_size,
    vs.volume_mount_point                                         AS drive,
    CAST(vs.available_bytes / 1073741824.0 AS decimal(18,1))      AS drive_free_gb,
    f.physical_name
FROM #files AS f
JOIN sys.master_files AS mf ON mf.database_id = DB_ID(f.database_name) AND mf.file_id = f.file_id
CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) AS vs
ORDER BY pct_used DESC;

DROP TABLE #files;
