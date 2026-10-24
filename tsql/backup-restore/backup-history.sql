/*
Script  : backup-history.sql
Purpose : Backup history from msdb with type, size, duration, LSNs and file path.
          Section 1 is the detailed history. Section 2 is the latest backup of
          each type per database, which is the quickest "are we covered?" check.
Usage   : Adjust @DaysBack and @DatabaseName (NULL = all databases).
Changes : Read-only.
Requires: SQL Server 2016 and later.
Source  : Based on MSSQLTips tip 1601 (backup history and databases with no backups).
*/
SET NOCOUNT ON;

DECLARE @DaysBack     int     = 7;
DECLARE @DatabaseName sysname = NULL;   -- for example N'SalesDB'

-- 1. Detailed backup history
SELECT
    CONVERT(sysname, SERVERPROPERTY('ServerName'))                AS server_name,
    s.database_name,
    CASE s.[type] WHEN 'D' THEN 'Full'
                  WHEN 'I' THEN 'Differential'
                  WHEN 'L' THEN 'Log'
                  ELSE s.[type] END                               AS backup_type,
    s.is_copy_only,
    s.backup_start_date,
    s.backup_finish_date,
    DATEDIFF(SECOND, s.backup_start_date, s.backup_finish_date)   AS duration_sec,
    CAST(s.backup_size / 1048576.0 AS decimal(18,2))              AS backup_size_mb,
    CAST(s.compressed_backup_size / 1048576.0 AS decimal(18,2))   AS compressed_size_mb,
    s.recovery_model,
    s.first_lsn,
    s.last_lsn,
    s.database_backup_lsn,
    s.user_name,
    m.physical_device_name,
    m.device_type                                                 -- 2 = disk, 7 = virtual device (third-party tools), 9 = URL
FROM msdb.dbo.backupset AS s
JOIN msdb.dbo.backupmediafamily AS m ON m.media_set_id = s.media_set_id
WHERE s.backup_start_date >= DATEADD(DAY, -@DaysBack, GETDATE())
  AND (@DatabaseName IS NULL OR s.database_name = @DatabaseName)
ORDER BY s.database_name, s.backup_finish_date DESC;

-- 2. Latest backup of each type per database (NULL = never backed up that way)
SELECT
    d.name AS database_name,
    d.recovery_model_desc,
    MAX(CASE WHEN b.[type] = 'D' THEN b.backup_finish_date END) AS last_full,
    MAX(CASE WHEN b.[type] = 'I' THEN b.backup_finish_date END) AS last_diff,
    MAX(CASE WHEN b.[type] = 'L' THEN b.backup_finish_date END) AS last_log
FROM sys.databases AS d
LEFT JOIN msdb.dbo.backupset AS b
       ON b.database_name = d.name
      AND b.is_copy_only = 0
WHERE d.name <> N'tempdb'
GROUP BY d.name, d.recovery_model_desc
ORDER BY last_full;
