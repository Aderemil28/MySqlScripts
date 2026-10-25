/*
Script  : find-invalid-xml-in-columns.sql
Purpose : Finds rows where a text column that is supposed to hold XML does not
          parse as XML. Typical use: an application fails to load its
          configuration after an upgrade, migration or manual edit, and you
          need to find the bad row.
Usage   : USE the application database. Set @SchemaName, @TableName and the
          column list in @Columns (comma separated). Run. Each returned row has
          at least one column that is not valid XML (NULLs are ignored).
Changes : Read-only.
Requires: SQL Server 2016 and later (STRING_SPLIT).
*/
SET NOCOUNT ON;

DECLARE @SchemaName sysname       = N'dbo';
DECLARE @TableName  sysname       = N'YourConfigTable';
DECLARE @Columns    nvarchar(max) = N'ConfigColumn1, ConfigColumn2';

DECLARE @select nvarchar(max) = N'', @where nvarchar(max) = N'', @sql nvarchar(max);

SELECT
    @select += N', ' + QUOTENAME(c) + N', CASE WHEN ' + QUOTENAME(c) + N' IS NULL THEN NULL '
             + N'WHEN TRY_CAST(' + QUOTENAME(c) + N' AS xml) IS NULL THEN ''INVALID'' ELSE ''OK'' END AS '
             + QUOTENAME(c + N'_xml_check'),
    @where  += N' OR (' + QUOTENAME(c) + N' IS NOT NULL AND TRY_CAST(' + QUOTENAME(c) + N' AS xml) IS NULL)'
FROM (SELECT LTRIM(RTRIM(value)) AS c FROM STRING_SPLIT(@Columns, N',') WHERE LTRIM(RTRIM(value)) <> N'') AS cols;

SET @sql = N'SELECT ' + STUFF(@select, 1, 2, N'')
         + N' FROM ' + QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@TableName)
         + N' WHERE ' + STUFF(@where, 1, 4, N'') + N';';

PRINT @sql;
EXEC sys.sp_executesql @sql;
