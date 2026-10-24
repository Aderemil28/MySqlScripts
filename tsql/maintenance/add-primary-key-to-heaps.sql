/*
Script  : add-primary-key-to-heaps.sql
Purpose : Lists user tables in the current database that have no primary key
          and no identity column, and generates statements to add a surrogate
          key column (PK_ID bigint IDENTITY) with a nonclustered primary key.
Usage   : USE the database. Run with @Execute = 0 and review the list.
          Only set @Execute = 1 after the application owner agrees: adding a
          column can break INSERT statements without a column list and
          SELECT * consumers, and it rewrites each table (size-of-data operation,
          log growth, blocking). Do this in a change window.
Changes : Alters tables when @Execute = 1.
Requires: SQL Server 2016 and later.
Source  : Based on a Stack Overflow answer (question 30769996). The original ran
          immediately against every table; this version previews first.
*/
SET NOCOUNT ON;

DECLARE @Execute bit = 0;

-- Candidate tables with size, so you know how heavy each change is
SELECT
    QUOTENAME(SCHEMA_NAME(t.schema_id)) + N'.' + QUOTENAME(t.name) AS table_name,
    SUM(CASE WHEN p.index_id IN (0, 1) THEN p.row_count ELSE 0 END) AS [row_count],
    CAST(SUM(p.reserved_page_count) * 8 / 1024.0 AS decimal(18,2))  AS reserved_mb,
    CASE WHEN EXISTS (SELECT 1 FROM sys.indexes AS i WHERE i.object_id = t.object_id AND i.index_id = 1)
         THEN 'Clustered' ELSE 'Heap' END                          AS storage
FROM sys.tables AS t
JOIN sys.dm_db_partition_stats AS p ON p.object_id = t.object_id
WHERE t.is_ms_shipped = 0
  AND NOT EXISTS (SELECT 1 FROM sys.key_constraints AS k WHERE k.parent_object_id = t.object_id AND k.type = 'PK')
  AND NOT EXISTS (SELECT 1 FROM sys.identity_columns AS ic WHERE ic.object_id = t.object_id)
GROUP BY t.schema_id, t.name, t.object_id
ORDER BY reserved_mb DESC;

DECLARE @sql nvarchar(max), @tbl nvarchar(300), @tname sysname;

DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT QUOTENAME(SCHEMA_NAME(t.schema_id)) + N'.' + QUOTENAME(t.name), t.name
    FROM sys.tables AS t
    WHERE t.is_ms_shipped = 0
      AND NOT EXISTS (SELECT 1 FROM sys.key_constraints AS k WHERE k.parent_object_id = t.object_id AND k.type = 'PK')
      AND NOT EXISTS (SELECT 1 FROM sys.identity_columns AS ic WHERE ic.object_id = t.object_id)
      AND COL_LENGTH(QUOTENAME(SCHEMA_NAME(t.schema_id)) + N'.' + QUOTENAME(t.name), N'PK_ID') IS NULL
    ORDER BY 1;

OPEN c;
FETCH NEXT FROM c INTO @tbl, @tname;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'ALTER TABLE ' + @tbl + N' ADD PK_ID bigint IDENTITY(1,1) NOT NULL;' + CHAR(13) + CHAR(10)
             + N'ALTER TABLE ' + @tbl + N' ADD CONSTRAINT ' + QUOTENAME(LEFT(N'PK_' + @tname + N'_PK_ID', 128))
             + N' PRIMARY KEY NONCLUSTERED (PK_ID);';
    PRINT @sql;

    IF @Execute = 1
    BEGIN
        BEGIN TRY
            EXEC sys.sp_executesql @sql;
        END TRY
        BEGIN CATCH
            PRINT N'   FAILED: ' + @tbl + N' - ' + ERROR_MESSAGE();
        END CATCH;
    END;

    FETCH NEXT FROM c INTO @tbl, @tname;
END;
CLOSE c;
DEALLOCATE c;
