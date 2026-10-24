/*
Script  : check-backup-file-exists.sql
Purpose : Confirms a backup file exists and that SQL Server can read it, before
          you run a RESTORE or point a job at a path. Catches "file not found"
          and "access denied" problems early.
Usage   : Set @BackupFile. Sections 1 and 2 need no special configuration.
          Section 3 uses xp_cmdshell and is optional.
Changes : Read-only, except section 3 which temporarily enables xp_cmdshell
          and turns it off again. Skip section 3 if xp_cmdshell is not allowed
          by your security policy.
Requires: SQL Server 2016 and later.
*/
SET NOCOUNT ON;

DECLARE @BackupFile nvarchar(512) = N'X:\SQLBackups\YourDatabase_FULL.bak';

-- 1. Does the file exist from the SQL Server service account's point of view?
DECLARE @exists TABLE (file_exists int, is_directory int, parent_dir_exists int);
INSERT INTO @exists EXEC master.dbo.xp_fileexist @BackupFile;
SELECT @BackupFile AS backup_file, * FROM @exists;

-- 2. Can SQL Server read it? Shows what is inside the backup.
RESTORE HEADERONLY   FROM DISK = @BackupFile;
RESTORE FILELISTONLY FROM DISK = @BackupFile;
-- RESTORE VERIFYONLY FROM DISK = @BackupFile WITH CHECKSUM;   -- full read of the file, can take a while

-- Which account needs folder permissions?
SELECT servicename, service_account
FROM sys.dm_server_services
WHERE servicename LIKE N'SQL Server (%';

/* 3. Optional: directory listing through xp_cmdshell, restoring the original setting afterwards.

DECLARE @was_enabled sql_variant = (SELECT value_in_use FROM sys.configurations WHERE name = N'xp_cmdshell');
DECLARE @cmd varchar(600) = 'dir "' + CONVERT(varchar(512), @BackupFile) + '"';

IF @was_enabled = 0
BEGIN
    EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
    EXEC sp_configure 'xp_cmdshell', 1;           RECONFIGURE;
END;

EXEC master.dbo.xp_cmdshell @cmd;

IF @was_enabled = 0
BEGIN
    EXEC sp_configure 'xp_cmdshell', 0; RECONFIGURE;
END;
*/
