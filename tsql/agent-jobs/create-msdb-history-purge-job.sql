/*
Script  : create-msdb-history-purge-job.sql
Purpose : Creates one SQL Agent job that keeps msdb small by deleting backup and
          restore history (step 1) and Agent job history (step 2) older than
          @KeepDays, every night.
          Replaces two separate jobs (backup history and job history) with one,
          so there is a single schedule and owner to manage.
Usage   : Set @KeepDays, @StartTime (HHMMSS) and @JobOwner, then run.
          Run tsql/maintenance/msdb-history-cleanup.sql first if msdb already
          holds years of history: the first nightly run would otherwise try to
          delete it all in one go.
          Re-running drops and re-creates the job.
          Agent's own history limit (SQL Server Agent > Properties > History)
          still applies on top of this; set it high enough not to cut history
          sooner than @KeepDays.
Changes : Creates (or re-creates) an Agent job.
Requires: SQL Server 2016 and later. sysadmin.
Fixes vs the original notes:
          - the jobs scripted from SSMS hard-coded schedule_uid values; those
            are now generated, so the script can run on any server
          - owner was a named admin login; now a variable (sa by default,
            which is the usual standard for job owners)
*/
USE msdb;
SET NOCOUNT ON;

DECLARE @JobName   sysname = N'DBA - msdb history purge';
DECLARE @KeepDays  int     = 120;
DECLARE @StartTime int     = 224500;   -- 10:45 PM
DECLARE @JobOwner  sysname = N'sa';

DECLARE @jobId uniqueidentifier, @rc int, @cmd1 nvarchar(max), @cmd2 nvarchar(max);

SET @cmd1 = N'DECLARE @cutoff datetime = DATEADD(DAY, -' + CAST(@KeepDays AS nvarchar(10)) + N', GETDATE());
EXEC msdb.dbo.sp_delete_backuphistory @oldest_date = @cutoff;';
SET @cmd2 = N'DECLARE @cutoff datetime = DATEADD(DAY, -' + CAST(@KeepDays AS nvarchar(10)) + N', GETDATE());
EXEC msdb.dbo.sp_purge_jobhistory @oldest_date = @cutoff;';

BEGIN TRANSACTION;

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = @JobName)
    EXEC @rc = msdb.dbo.sp_delete_job @job_name = @JobName, @delete_unused_schedule = 1;

EXEC @rc = msdb.dbo.sp_add_job
     @job_name         = @JobName,
     @enabled          = 1,
     @description      = N'Deletes msdb backup/restore history and Agent job history older than the retention set in the step commands.',
     @category_name    = N'Database Maintenance',
     @owner_login_name = @JobOwner,
     @job_id           = @jobId OUTPUT;
IF @@ERROR <> 0 OR @rc <> 0 GOTO QuitWithRollback;

EXEC @rc = msdb.dbo.sp_add_jobstep
     @job_id = @jobId, @step_id = 1, @step_name = N'Delete backup history',
     @subsystem = N'TSQL', @database_name = N'msdb', @command = @cmd1,
     @on_success_action = 3,   -- go to the next step
     @on_fail_action = 3;      -- still purge job history if this step fails
IF @@ERROR <> 0 OR @rc <> 0 GOTO QuitWithRollback;

EXEC @rc = msdb.dbo.sp_add_jobstep
     @job_id = @jobId, @step_id = 2, @step_name = N'Purge job history',
     @subsystem = N'TSQL', @database_name = N'msdb', @command = @cmd2,
     @on_success_action = 1,   -- quit reporting success
     @on_fail_action = 2;      -- quit reporting failure
IF @@ERROR <> 0 OR @rc <> 0 GOTO QuitWithRollback;

EXEC @rc = msdb.dbo.sp_add_jobschedule
     @job_id = @jobId, @name = N'Daily', @enabled = 1,
     @freq_type = 4, @freq_interval = 1,          -- every day
     @active_start_time = @StartTime;
IF @@ERROR <> 0 OR @rc <> 0 GOTO QuitWithRollback;

EXEC @rc = msdb.dbo.sp_add_jobserver @job_id = @jobId, @server_name = N'(local)';
IF @@ERROR <> 0 OR @rc <> 0 GOTO QuitWithRollback;

COMMIT TRANSACTION;
PRINT 'Created job: ' + @JobName;
GOTO EndSave;

QuitWithRollback:
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT 'Failed; nothing was created.';
EndSave:
