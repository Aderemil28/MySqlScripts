/*
Script  : file-growth-diagnostic-toolkit.sql
Purpose : Investigates disk space pressure and autogrowth behaviour for data and
          log files: current growth settings, growth trend from backup history,
          actual autogrowth events from the default trace, Instant File
          Initialization status, biggest tables, and the fix (fixed MB growth).
Usage   : Run each numbered section on its own. Replace the placeholder names
          (YourDatabaseName, YourLogicalDataFileName) where they appear.
Changes : Sections 1 to 6 and 8 are read-only. Section 7 changes file growth
          settings (applies immediately, no restart, no downtime).
Requires: SQL Server 2016 and later.

Quick decision notes
  - Percent-based autogrowth is risky on any file over a few GB. Convert to fixed MB.
  - A "Data File Auto Grow" event with a Duration in the tens of millions of
    microseconds (minutes) strongly suggests IFI is disabled. Check section 5.
  - tempdb growing every few seconds by a small amount means tempdb is
    undersized. Pre-size the files rather than relying on autogrowth.
  - Backup history (section 2) is the most reliable long-term growth trend;
    the default trace rolls over quickly.
  - Before treating a space issue as an emergency, work out GB per day of
    growth against free space. The real number often shows more runway than
    a first look suggests.
  - Check every drive (data, log, backup, tempdb and C:) when looking at one.
*/

--------------------------------------------------------------------------------
-- 1. Current file sizes, max size and autogrowth settings
--------------------------------------------------------------------------------
SELECT
    DB_NAME(database_id)                    AS database_name,
    name                                    AS logical_file_name,
    physical_name,
    type_desc,                              -- ROWS = data, LOG = log
    CAST(size / 128.0 AS decimal(18,2))     AS size_mb,
    CASE WHEN max_size = -1 THEN 'Unlimited'
         ELSE CAST(CAST(max_size / 128.0 AS decimal(18,0)) AS varchar(20)) + ' MB' END AS max_size,
    CASE WHEN is_percent_growth = 1 THEN CAST(growth AS varchar(10)) + ' %'
         ELSE CAST(growth / 128 AS varchar(10)) + ' MB' END AS growth_setting
FROM sys.master_files
-- WHERE type_desc = 'LOG'
ORDER BY size DESC;

--------------------------------------------------------------------------------
-- 2. Growth trend from full backup sizes (msdb)
--    Compare backup_size_mb across dates to estimate MB or GB per day.
--------------------------------------------------------------------------------
SELECT
    bs.database_name,
    CAST(bs.backup_start_date AS date)                        AS backup_date,
    CAST(bs.backup_size / 1048576.0 AS decimal(18,0))         AS backup_size_mb,
    CAST(bs.compressed_backup_size / 1048576.0 AS decimal(18,0)) AS compressed_mb
FROM msdb.dbo.backupset AS bs
WHERE bs.type = 'D'
  AND bs.is_copy_only = 0
  -- AND bs.database_name = N'YourDatabaseName'
ORDER BY bs.database_name, bs.backup_start_date DESC;

--------------------------------------------------------------------------------
-- 3. Autogrowth events from the default trace
--    Duration is in microseconds. Long durations on data files point to IFI
--    being disabled.
--------------------------------------------------------------------------------
DECLARE @path nvarchar(260);

SELECT @path = REVERSE(SUBSTRING(REVERSE(path), CHARINDEX(N'\', REVERSE(path)), 260)) + N'log.trc'
FROM sys.traces
WHERE is_default = 1;

IF @path IS NULL
    PRINT N'Default trace is not enabled. See section 4.';
ELSE
    SELECT
        te.name                                   AS event_name,
        t.DatabaseName,
        t.FileName,
        t.StartTime,
        CAST(t.Duration / 1000000.0 AS decimal(18,2)) AS duration_sec,
        CAST(t.IntegerData * 8 / 1024.0 AS decimal(18,2)) AS growth_mb
    FROM sys.fn_trace_gettable(@path, DEFAULT) AS t
    JOIN sys.trace_events AS te ON te.trace_event_id = t.EventClass
    WHERE te.name IN (N'Data File Auto Grow', N'Log File Auto Grow')
      -- AND t.DatabaseName = N'YourDatabaseName'
    ORDER BY t.StartTime DESC;

--------------------------------------------------------------------------------
-- 4. Is the default trace enabled? (value_in_use = 1)
--    To enable: EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
--               EXEC sp_configure 'default trace enabled', 1; RECONFIGURE;
--------------------------------------------------------------------------------
SELECT name, value_in_use
FROM sys.configurations
WHERE name = N'default trace enabled';

--------------------------------------------------------------------------------
-- 5. Instant File Initialization (IFI)
--    'N' means new data file space is zero-filled, which makes growth slow and
--    can block. Log files are always zero-filled, IFI or not.
--    To enable: add the SQL Server service account to the local policy
--    "Perform volume maintenance tasks" (secpol.msc or GPO), then restart the
--    service. In a regulated environment, get it approved and documented.
--------------------------------------------------------------------------------
SELECT servicename, service_account, instant_file_initialization_enabled, last_startup_time
FROM sys.dm_server_services
WHERE servicename LIKE N'SQL Server (%';

--------------------------------------------------------------------------------
-- 6. Biggest tables in the current database (why it is growing)
--    USE the database first.
--------------------------------------------------------------------------------
SELECT TOP (20)
    OBJECT_SCHEMA_NAME(p.object_id) + N'.' + OBJECT_NAME(p.object_id) AS table_name,
    CAST(SUM(p.reserved_page_count) * 8 / 1024.0 AS decimal(18,2))  AS reserved_mb,
    CAST(SUM(p.used_page_count) * 8 / 1024.0 AS decimal(18,2))      AS used_mb,
    SUM(CASE WHEN p.index_id IN (0, 1) THEN p.row_count ELSE 0 END) AS [row_count]
FROM sys.dm_db_partition_stats AS p
WHERE OBJECTPROPERTY(p.object_id, 'IsMSShipped') = 0
GROUP BY p.object_id
ORDER BY reserved_mb DESC;

--------------------------------------------------------------------------------
-- 7. Change autogrowth from percent to fixed MB (the fix)
--    Percent growth on a large file means huge, unpredictable growth events
--    (10% of a 500 GB file is a 50 GB jump). Fixed MB is predictable.
--------------------------------------------------------------------------------
/*
ALTER DATABASE [YourDatabaseName]
MODIFY FILE (NAME = N'YourLogicalDataFileName', FILEGROWTH = 4096MB);   -- logical name from section 1

ALTER DATABASE [YourDatabaseName]
MODIFY FILE (NAME = N'YourLogicalLogFileName', FILEGROWTH = 512MB);
*/

--------------------------------------------------------------------------------
-- 8. Confirm the change
--------------------------------------------------------------------------------
SELECT
    name AS logical_file_name,
    CAST(size / 128.0 AS decimal(18,2)) AS size_mb,
    CASE WHEN is_percent_growth = 1 THEN CAST(growth AS varchar(10)) + ' %'
         ELSE CAST(growth / 128 AS varchar(10)) + ' MB' END AS growth_setting
FROM sys.master_files
WHERE database_id = DB_ID(N'YourDatabaseName');
