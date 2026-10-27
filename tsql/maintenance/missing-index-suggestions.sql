/*
Script  : missing-index-suggestions.sql
Purpose : The missing indexes SQL Server's optimizer has asked for since the
          last restart, ranked by estimated benefit, with a CREATE INDEX
          statement for each.
Usage   : Run as is (whole server), or set @DatabaseName.
          These are SUGGESTIONS, not instructions. Before creating any index:
            - check it doesn't duplicate or overlap an existing index
              (duplicate-indexes.sql); widen an existing one instead
            - combine suggestions on the same table rather than creating each
            - remember every index slows down inserts, updates and deletes
            - test with the workload, and get the application owner's agreement
          The numbers reset at restart and when an index on the table changes,
          so a freshly restarted server shows little.
Changes : Read-only. The CREATE INDEX statements are only printed.
Requires: SQL Server 2016 and later. VIEW SERVER STATE.
Fixes vs the original notes:
          - the generated name used group and index handles only; now it
            includes the table so names don't collide across databases
          - added database and table columns, and the column lists split out,
            so suggestions on the same table are easy to combine
*/
SET NOCOUNT ON;

DECLARE @DatabaseName sysname = NULL;   -- NULL = all databases
DECLARE @MinBenefit   float   = 10;     -- hide tiny suggestions

SELECT TOP (50)
    CONVERT(varchar(19), GETDATE(), 126)                                AS captured_at,
    DB_NAME(mid.database_id)                                            AS database_name,
    OBJECT_SCHEMA_NAME(mid.object_id, mid.database_id) + N'.'
        + OBJECT_NAME(mid.object_id, mid.database_id)                   AS table_name,
    CONVERT(decimal(28,1), migs.avg_total_user_cost * migs.avg_user_impact
        * (migs.user_seeks + migs.user_scans))                          AS estimated_benefit,
    migs.avg_user_impact                                                AS avg_pct_improvement,
    migs.user_seeks,
    migs.user_scans,
    migs.last_user_seek,
    mid.equality_columns,
    mid.inequality_columns,
    mid.included_columns,
    N'CREATE INDEX ' + QUOTENAME(N'IX_' + OBJECT_NAME(mid.object_id, mid.database_id) + N'_missing_'
            + CONVERT(nvarchar(10), mig.index_group_handle) + N'_' + CONVERT(nvarchar(10), mid.index_handle))
        + N' ON ' + mid.statement
        + N' (' + ISNULL(mid.equality_columns, N'')
        + CASE WHEN mid.equality_columns IS NOT NULL AND mid.inequality_columns IS NOT NULL THEN N', ' ELSE N'' END
        + ISNULL(mid.inequality_columns, N'') + N')'
        + ISNULL(N' INCLUDE (' + mid.included_columns + N')', N'') + N';'  AS create_index_statement
FROM sys.dm_db_missing_index_groups AS mig
JOIN sys.dm_db_missing_index_group_stats AS migs ON migs.group_handle = mig.index_group_handle
JOIN sys.dm_db_missing_index_details     AS mid  ON mid.index_handle  = mig.index_handle
WHERE (@DatabaseName IS NULL OR mid.database_id = DB_ID(@DatabaseName))
  AND migs.avg_total_user_cost * migs.avg_user_impact * (migs.user_seeks + migs.user_scans) > @MinBenefit
ORDER BY estimated_benefit DESC;
