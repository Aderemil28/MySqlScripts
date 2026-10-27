/*
Script  : msdb-history-cleanup.sql
Purpose : One-off cleanup of a large msdb: how big it is and how far back its
          backup and job history goes, then a purge of backup/restore history
          and Agent job history older than @KeepDays, in weekly chunks so the
          msdb log and blocking stay small.
          For ongoing cleanup, schedule tsql/agent-jobs/create-msdb-history-purge-job.sql.
Usage   : 1. Run with @Execute = 0: shows the size, the oldest history, and the
             chunks it would delete.
          2. Run with @Execute = 1 in a quiet period. The first run on years of
             history can take a long time; it can be stopped and re-run safely.
          3. Optional: shrink the msdb log once afterwards (section 4). Only
             after a one-off purge, never as routine.
Changes : Deletes history from msdb when @Execute = 1. Nothing else.
Requires: SQL Server 2016 and later. sysadmin.
Notes   : msdb uses the SIMPLE recovery model by default. If yours is FULL,
          log backups must be running for it, or its log keeps growing; check
          section 1 before purging.
          Deleting history also removes what backup-history.sql and
          failed-jobs.sql can report on for those dates.
*/
USE msdb;
SET NOCOUNT ON;

DECLARE @KeepDays  int = 120;   -- keep this many days of history
DECLARE @ChunkDays int = 7;     -- delete this many days per batch
DECLARE @Execute   bit = 0;

DECLARE @TargetDate datetime = DATEADD(DAY, -@KeepDays, GETDATE());

-- 1. Size, recovery model and how far back the history goes
SELECT  DB_NAME()                                                  AS database_name,
        CAST(SUM(CASE WHEN type = 0 THEN size END) / 128.0 AS decimal(18,0)) AS data_mb,
        CAST(SUM(CASE WHEN type = 1 THEN size END) / 128.0 AS decimal(18,0)) AS log_mb,
        DATABASEPROPERTYEX(N'msdb', 'Recovery')                    AS recovery_model,
        (SELECT MIN(backup_start_date) FROM dbo.backupset)         AS oldest_backup_history,
        (SELECT msdb.dbo.agent_datetime(MIN(run_date), 0) FROM dbo.sysjobhistory) AS oldest_job_history,
        (SELECT COUNT(*) FROM dbo.backupset)                       AS backupset_rows,
        (SELECT COUNT(*) FROM dbo.sysjobhistory)                   AS jobhistory_rows,
        @TargetDate                                                AS will_delete_before
FROM sys.database_files;

-- Largest msdb tables (backup history and job history are usually the top)
SELECT TOP (10) OBJECT_NAME(ps.object_id) AS table_name,
       CAST(SUM(ps.reserved_page_count) / 128.0 AS decimal(18,0)) AS reserved_mb,
       SUM(CASE WHEN ps.index_id < 2 THEN ps.row_count ELSE 0 END) AS row_count
FROM sys.dm_db_partition_stats AS ps
GROUP BY ps.object_id
ORDER BY reserved_mb DESC;

-- 2. Backup and restore history, in chunks
DECLARE @ChunkDate datetime = (SELECT MIN(backup_start_date) FROM dbo.backupset);

IF @ChunkDate IS NULL OR @ChunkDate >= @TargetDate
BEGIN
    PRINT 'Backup history: nothing older than ' + CONVERT(varchar(20), @TargetDate, 120);
END
ELSE
BEGIN
    PRINT 'Backup history starts at ' + CONVERT(varchar(20), @ChunkDate, 120);
    WHILE @ChunkDate < @TargetDate
    BEGIN
        SET @ChunkDate = DATEADD(DAY, @ChunkDays, @ChunkDate);
        IF @ChunkDate > @TargetDate SET @ChunkDate = @TargetDate;

        PRINT 'Delete backup history before ' + CONVERT(varchar(20), @ChunkDate, 120);
        IF @Execute = 1
        BEGIN
            EXEC dbo.sp_delete_backuphistory @oldest_date = @ChunkDate;
            CHECKPOINT;   -- lets the SIMPLE recovery log reuse space between chunks
        END;
    END;
END;

-- 3. Agent job history
PRINT 'Purge job history before ' + CONVERT(varchar(20), @TargetDate, 120);
IF @Execute = 1
    EXEC dbo.sp_purge_jobhistory @oldest_date = @TargetDate;

IF @Execute = 1
BEGIN
    PRINT 'Purge complete. Re-run section 1 to see the result.';
    EXEC sp_spaceused;
END
ELSE
BEGIN
    PRINT 'Preview only. Set @Execute = 1 to delete.';
END

-- 4. Optional, once, after a large one-off purge: give the log space back.
--    Use the logical name from sys.database_files (MSDBLog by default).
-- CHECKPOINT;
-- DBCC SHRINKFILE (MSDBLog, 512);
-- DBCC SQLPERF(LOGSPACE);
