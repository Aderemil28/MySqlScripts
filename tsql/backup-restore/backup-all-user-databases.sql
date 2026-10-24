/*
Script  : backup-all-user-databases.sql
Purpose : Full backup of every online, read-write user database to one folder,
          one file per database, named <db>_FULL_<yyyymmdd_hhmmss>.bak.
Usage   : Set @BackupPath and @CopyOnly, run with @Execute = 0 to review the
          commands, then set @Execute = 1 to run them.
Changes : Takes backups when @Execute = 1. Use COPY_ONLY for ad hoc backups so
          the regular differential base and log chain are not affected.
Requires: SQL Server 2016 and later.
Source  : Adapted from MSSQLTips tip 1070 (simple script to back up all databases).
*/
SET NOCOUNT ON;

DECLARE @BackupPath nvarchar(512) = N'X:\SQLBackups\';  -- folder must exist and be writable by the SQL Server service account
DECLARE @CopyOnly   bit           = 1;                  -- 1 = COPY_ONLY (recommended for ad hoc backups)
DECLARE @Execute    bit           = 0;                  -- 0 = print commands only, 1 = run them

DECLARE @Stamp nvarchar(20) = REPLACE(REPLACE(REPLACE(CONVERT(nvarchar(19), SYSDATETIME(), 120), N'-', N''), N':', N''), N' ', N'_');
DECLARE @name  sysname, @sql nvarchar(max);

IF RIGHT(@BackupPath, 1) <> N'\' SET @BackupPath += N'\';

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT d.name
    FROM sys.databases AS d
    WHERE d.database_id > 4                 -- skip master, tempdb, model, msdb
      AND d.state_desc = N'ONLINE'
      AND d.is_read_only = 0
      AND d.is_in_standby = 0               -- skip log shipping standby copies
      AND d.source_database_id IS NULL      -- skip database snapshots
      AND sys.fn_hadr_backup_is_preferred_replica(d.name) = 1  -- respects AG backup preference; returns 1 outside an AG
    ORDER BY d.name;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @name;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'BACKUP DATABASE ' + QUOTENAME(@name)
             + N' TO DISK = N''' + @BackupPath + REPLACE(@name, N'''', N'''''') + N'_FULL_' + @Stamp + N'.bak'''
             + N' WITH ' + CASE WHEN @CopyOnly = 1 THEN N'COPY_ONLY, ' ELSE N'' END
             + N'COMPRESSION, CHECKSUM, STATS = 10;';

    PRINT @sql;

    IF @Execute = 1
    BEGIN
        BEGIN TRY
            EXEC sys.sp_executesql @sql;
        END TRY
        BEGIN CATCH
            PRINT N'FAILED: ' + @name + N' - ' + ERROR_MESSAGE();
        END CATCH;
    END;

    FETCH NEXT FROM db_cursor INTO @name;
END;

CLOSE db_cursor;
DEALLOCATE db_cursor;
