/*
Script  : schema-object-counts.sql
Purpose : Object inventory of the current database (tables, keys, indexes,
          procedures, views, functions, triggers, users) plus row counts per
          table. Run on the source and the target after a migration, a schema-only
          copy (dacpac), or a refresh, and compare the two outputs to prove
          nothing is missing.
Usage   : USE the database and run. Run the same script on the other side.
Changes : Read-only.
Requires: SQL Server 2016 and later.
*/

-- 1. Object counts by type
SELECT o.type_desc, COUNT(*) AS object_count
FROM sys.objects AS o
WHERE o.is_ms_shipped = 0
GROUP BY o.type_desc
UNION ALL
SELECT 'INDEX (non-heap)', COUNT(*)
FROM sys.indexes AS i
JOIN sys.objects AS o ON o.object_id = i.object_id
WHERE o.is_ms_shipped = 0 AND i.index_id > 0
UNION ALL
SELECT 'DATABASE USER', COUNT(*)
FROM sys.database_principals
WHERE type IN ('S', 'U', 'G') AND principal_id > 4
ORDER BY 1;

-- 2. Table list with row counts (0 rows everywhere = schema-only copy worked)
SELECT
    SCHEMA_NAME(t.schema_id) + N'.' + t.name AS table_name,
    SUM(p.rows)                              AS [row_count],
    t.create_date,
    t.modify_date
FROM sys.tables AS t
JOIN sys.partitions AS p ON p.object_id = t.object_id AND p.index_id IN (0, 1)
WHERE t.is_ms_shipped = 0
GROUP BY t.schema_id, t.name, t.create_date, t.modify_date
ORDER BY table_name;
