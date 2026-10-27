/*
Script  : table-sizes-all-databases.sql
Purpose : Size of every user table in every online database: reserved and used
          space, split into table data, indexes and LOB (large object) data,
          plus row count. Finds which tables are behind a growing database.
Usage   : Run as is for the whole server, or set @DatabaseName for one database.
          @TopN limits the output to the largest tables.
Changes : Read-only.
Requires: SQL Server 2016 and later.
Fixes vs the original notes:
          - sp_MSforeachdb is undocumented and can silently skip databases;
            replaced with a cursor over sys.databases
          - sizes were INT MB from integer division, so tables under 1 MB
            showed 0; now decimal MB
          - grouped by object and schema name only, which could merge tables
            with the same name in different schemas; now grouped by object_id
*/
SET NOCOUNT ON;

DECLARE @DatabaseName sysname = NULL;   -- NULL = all databases
DECLARE @TopN         int     = 50;

IF OBJECT_ID(N'tempdb..#table_sizes') IS NOT NULL DROP TABLE #table_sizes;
CREATE TABLE #table_sizes
(
    database_name sysname, schema_name sysname, table_name sysname,
    total_reserved_mb decimal(18,2), total_used_mb decimal(18,2),
    table_reserved_mb decimal(18,2), table_used_mb decimal(18,2),
    indexes_reserved_mb decimal(18,2), indexes_used_mb decimal(18,2),
    lob_reserved_mb decimal(18,2), lob_used_mb decimal(18,2),
    row_count bigint
);

DECLARE @inner nvarchar(max) = N'
INSERT INTO #table_sizes
SELECT DB_NAME(), sch.name, obj.name,
       SUM(ps.reserved_page_count) / 128.0,
       SUM(ps.used_page_count) / 128.0,
       SUM(CASE WHEN ps.index_id < 2 THEN ps.in_row_reserved_page_count + ps.row_overflow_reserved_page_count ELSE 0 END) / 128.0,
       SUM(CASE WHEN ps.index_id < 2 THEN ps.in_row_used_page_count + ps.row_overflow_used_page_count ELSE 0 END) / 128.0,
       SUM(CASE WHEN ps.index_id >= 2 THEN ps.reserved_page_count ELSE 0 END) / 128.0,
       SUM(CASE WHEN ps.index_id >= 2 THEN ps.used_page_count ELSE 0 END) / 128.0,
       SUM(ps.lob_reserved_page_count) / 128.0,
       SUM(ps.lob_used_page_count) / 128.0,
       SUM(CASE WHEN ps.index_id < 2 THEN ps.row_count ELSE 0 END)
FROM sys.dm_db_partition_stats AS ps
JOIN sys.objects AS obj ON obj.object_id = ps.object_id
JOIN sys.schemas AS sch ON sch.schema_id = obj.schema_id
WHERE obj.is_ms_shipped = 0
  AND obj.type = ''U''
GROUP BY ps.object_id, sch.name, obj.name;';

DECLARE @db sysname, @proc nvarchar(300);
DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases
    WHERE state_desc = N'ONLINE' AND database_id > 4
      AND (@DatabaseName IS NULL OR name = @DatabaseName)
    ORDER BY name;
OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @db;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @proc = QUOTENAME(@db) + N'.sys.sp_executesql';
    BEGIN TRY
        EXEC @proc @inner;
    END TRY
    BEGIN CATCH
        PRINT N'Skipped ' + @db + N': ' + ERROR_MESSAGE();
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @db;
END;
CLOSE db_cursor;
DEALLOCATE db_cursor;

SELECT TOP (@TopN) *
FROM #table_sizes
ORDER BY total_reserved_mb DESC;

DROP TABLE #table_sizes;
