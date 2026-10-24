/*
Script  : statistics-properties.sql
Purpose : When each statistic on a table was last updated, how many rows were
          sampled, and how many modifications have happened since. High
          modification_counter with an old last_updated is a candidate for
          UPDATE STATISTICS.
Usage   : USE the database, set @TableName (schema.table) or leave NULL for the
          whole database (top 200 by modifications).
Changes : Read-only.
Requires: SQL Server 2016 and later.
*/
DECLARE @TableName nvarchar(300) = NULL;   -- for example N'dbo.Orders'

SELECT TOP (200)
    OBJECT_SCHEMA_NAME(st.object_id) + N'.' + OBJECT_NAME(st.object_id) AS table_name,
    st.stats_id,
    st.name                                                    AS stats_name,
    st.auto_created,
    st.filter_definition,
    sp.last_updated,
    sp.rows,
    sp.rows_sampled,
    CAST(100.0 * sp.rows_sampled / NULLIF(sp.rows, 0) AS decimal(5,1)) AS sample_pct,
    sp.steps,
    sp.modification_counter
FROM sys.stats AS st
CROSS APPLY sys.dm_db_stats_properties(st.object_id, st.stats_id) AS sp
WHERE OBJECTPROPERTY(st.object_id, 'IsMSShipped') = 0
  AND (@TableName IS NULL OR st.object_id = OBJECT_ID(@TableName))
ORDER BY sp.modification_counter DESC
OPTION (RECOMPILE);
