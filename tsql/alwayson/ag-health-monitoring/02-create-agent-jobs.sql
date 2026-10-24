/*
Script  : 02-create-agent-jobs.sql  (AG health monitoring, step 2 of 3)
Purpose : Creates two Agent jobs:
            DBA - AG Health Collect : runs dbo.usp_CollectAGHealth every 15 minutes
            DBA - AG Health Purge   : runs dbo.usp_PurgeAGHealth daily at 01:30
Usage   : Run on every replica after 01-create-table-and-procedures.sql.
          Change @CollectEveryMinutes or @RetentionDays if needed.
          Re-running is safe: existing jobs with the same names are skipped.
Changes : Creates Agent jobs and schedules in msdb.
Requires: SQL Server 2016 and later.
*/
USE msdb;
GO

DECLARE @CollectEveryMinutes int = 15;
DECLARE @RetentionDays       int = 30;
DECLARE @Owner sysname = SUSER_SNAME(0x01);   -- sa (or its renamed equivalent)
DECLARE @cmd nvarchar(200);

IF NOT EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name = N'DBA - AG Health Collect')
BEGIN
    EXEC dbo.sp_add_job        @job_name = N'DBA - AG Health Collect',
                               @description = N'Logs AG replica and database health to DBAUtil.dbo.AGHealthStatus',
                               @owner_login_name = @Owner;
    EXEC dbo.sp_add_jobstep    @job_name = N'DBA - AG Health Collect',
                               @step_name = N'Collect',
                               @subsystem = N'TSQL',
                               @database_name = N'DBAUtil',
                               @command = N'EXEC dbo.usp_CollectAGHealth;';
    EXEC dbo.sp_add_jobschedule @job_name = N'DBA - AG Health Collect',
                               @name = N'Every N minutes - AG health',
                               @freq_type = 4, @freq_interval = 1,          -- daily
                               @freq_subday_type = 4,                       -- minutes
                               @freq_subday_interval = @CollectEveryMinutes,
                               @active_start_time = 0;
    EXEC dbo.sp_add_jobserver  @job_name = N'DBA - AG Health Collect';
END;

SET @cmd = N'EXEC dbo.usp_PurgeAGHealth @RetentionDays = ' + CAST(@RetentionDays AS nvarchar(10)) + N';';

IF NOT EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name = N'DBA - AG Health Purge')
BEGIN
    EXEC dbo.sp_add_job        @job_name = N'DBA - AG Health Purge',
                               @description = N'Deletes AG health rows older than the retention period',
                               @owner_login_name = @Owner;
    EXEC dbo.sp_add_jobstep    @job_name = N'DBA - AG Health Purge',
                               @step_name = N'Purge',
                               @subsystem = N'TSQL',
                               @database_name = N'DBAUtil',
                               @command = @cmd;
    EXEC dbo.sp_add_jobschedule @job_name = N'DBA - AG Health Purge',
                               @name = N'Daily 01:30 - AG health purge',
                               @freq_type = 4, @freq_interval = 1,
                               @active_start_time = 13000;                  -- 01:30:00
    EXEC dbo.sp_add_jobserver  @job_name = N'DBA - AG Health Purge';
END;
GO

-- Test
-- EXEC msdb.dbo.sp_start_job @job_name = N'DBA - AG Health Collect';
-- SELECT TOP (50) * FROM DBAUtil.dbo.AGHealthStatus ORDER BY ID DESC;
