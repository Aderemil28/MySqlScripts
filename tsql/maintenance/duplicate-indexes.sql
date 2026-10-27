/*
Script  : duplicate-indexes.sql
Purpose : Two index checks for the current database:
            1. Exact duplicates: same table, same key columns in the same
               order, same included columns. One of each pair can go.
            2. Overlapping indexes: one index's key columns are the leading
               columns of another's. The narrower one is often redundant.
          Each duplicate costs disk, memory, backup time and slows every
          insert, update and delete on the table.
Usage   : USE the database, then run. Before dropping anything:
            - keep the one backing a primary key or unique constraint
            - check filtered indexes and index options are really the same
            - check usage (sys.dm_db_index_usage_stats) and index hints in code
            - script the index out first, and drop in a change window
Changes : Read-only.
Requires: SQL Server 2016 and later.
Fixes vs the original notes:
          - used sys.sysindexkeys, a SQL Server 2000 compatibility view; now
            sys.index_columns
          - compared included columns in key order; now by column, so the same
            included columns in a different order still match
          - added the overlap check and the constraint and filter columns
*/
SET NOCOUNT ON;

WITH index_cols AS
(
    SELECT  i.object_id,
            i.index_id,
            i.name,
            i.type_desc,
            i.is_primary_key,
            i.is_unique_constraint,
            i.has_filter,
            i.filter_definition,
            STUFF((SELECT N',' + CAST(ic.column_id AS nvarchar(10))
                          + CASE WHEN ic.is_descending_key = 1 THEN N' DESC' ELSE N'' END
                   FROM sys.index_columns AS ic
                   WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
                   ORDER BY ic.key_ordinal
                   FOR XML PATH('')), 1, 1, N'') AS key_cols,
            ISNULL(STUFF((SELECT N',' + CAST(ic.column_id AS nvarchar(10))
                   FROM sys.index_columns AS ic
                   WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 1
                   ORDER BY ic.column_id
                   FOR XML PATH('')), 1, 1, N''), N'') AS include_cols
    FROM sys.indexes AS i
    JOIN sys.objects AS o ON o.object_id = i.object_id
    WHERE o.is_ms_shipped = 0
      AND i.index_id > 0                    -- not heaps
      AND i.type IN (1, 2)                  -- clustered and nonclustered rowstore
),
named AS
(
    SELECT ic.*,
           STUFF((SELECT N', ' + c.name
                  FROM sys.index_columns AS x
                  JOIN sys.columns AS c ON c.object_id = x.object_id AND c.column_id = x.column_id
                  WHERE x.object_id = ic.object_id AND x.index_id = ic.index_id AND x.is_included_column = 0
                  ORDER BY x.key_ordinal
                  FOR XML PATH('')), 1, 2, N'') AS key_column_names
    FROM index_cols AS ic
)
SELECT  CASE WHEN a.key_cols = b.key_cols AND a.include_cols = b.include_cols
             THEN N'1. EXACT DUPLICATE' ELSE N'2. OVERLAPPING (left-based subset)' END AS finding,
        OBJECT_SCHEMA_NAME(a.object_id) + N'.' + OBJECT_NAME(a.object_id)       AS table_name,
        a.name                                                                  AS index_name,
        a.key_column_names                                                      AS index_keys,
        b.name                                                                  AS covered_by_or_same_as,
        b.key_column_names                                                      AS other_index_keys,
        CASE WHEN a.is_primary_key = 1 OR a.is_unique_constraint = 1 THEN N'Backs a constraint: keep'
             WHEN a.has_filter = 1 OR b.has_filter = 1 THEN N'Filtered index: compare filters'
             ELSE N'Candidate to drop' END                                      AS note,
        a.filter_definition,
        b.filter_definition                                                     AS other_filter_definition
FROM named AS a
JOIN named AS b
  ON  b.object_id = a.object_id
  AND b.index_id <> a.index_id
  AND (
        -- exact: same keys and includes; list each pair once
        (a.key_cols = b.key_cols AND a.include_cols = b.include_cols AND a.index_id > b.index_id)
        -- overlap: a's keys are the leading keys of b's, and b is wider
     OR (b.key_cols LIKE a.key_cols + N',%' AND a.include_cols = N'')
      )
ORDER BY table_name, finding, index_name;
