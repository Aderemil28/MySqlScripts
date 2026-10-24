/*
Script  : backup-lsn-chain.sql
Purpose : Shows the LSN chain for one database so you can work out which full,
          differential and log backups are needed for a point-in-time restore,
          or why a differential or log restore is refused.
Usage   : Set @DatabaseName. Read from the bottom up:
            - a differential's database_backup_lsn must equal the checkpoint_lsn
              of the full it is based on
            - each log's first_lsn must equal the previous log's last_lsn
Changes : Read-only.
Requires: SQL Server 2016 and later.
*/
SET NOCOUNT ON;

DECLARE @DatabaseName sysname = N'YourDatabaseName';

SELECT
    b.database_name,
    CASE b.[type] WHEN 'D' THEN 'Full' WHEN 'I' THEN 'Differential' WHEN 'L' THEN 'Log' END AS backup_type,
    b.is_copy_only,
    b.backup_start_date,
    b.backup_finish_date,
    b.first_lsn,
    b.last_lsn,
    b.checkpoint_lsn,
    b.database_backup_lsn,
    mf.physical_device_name
FROM msdb.dbo.backupset AS b
JOIN msdb.dbo.backupmediafamily AS mf ON mf.media_set_id = b.media_set_id
WHERE b.database_name = @DatabaseName
ORDER BY b.backup_finish_date DESC;
