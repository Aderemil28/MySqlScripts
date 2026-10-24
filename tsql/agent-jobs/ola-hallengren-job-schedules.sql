/*
Script  : ola-hallengren-job-schedules.sql
Purpose : Adds schedules to the Agent jobs created by Ola Hallengren's
          Maintenance Solution (which creates the jobs without schedules).
          Default plan:
            Sunday 00:01-00:04  cleanup jobs (CommandLog, output files, backup and job history)
            Daily  00:05        system database full backup
            Daily  00:10        system database integrity check
            Daily  01:00        user database index and statistics maintenance
            Daily  02:00        user database integrity check
            Daily  03:00        user database full backup
            Daily  15:00        user database differential backup
            Every 5 minutes     user database log backup
Usage   : Install the Maintenance Solution first (https://ola.hallengren.com).
          Adjust times to your maintenance windows and backup policy, then run.
          Running it twice adds duplicate schedules, so check
          jobs-schedule-and-next-run.sql first.
Changes : Adds schedules to existing Agent jobs.
Requires: SQL Server 2016 and later, Maintenance Solution 2020 and later.
*/
USE msdb;
GO

-- Take care of cleanup jobs first  *********


-- Add schedule for CommandLog Cleanup job
EXEC msdb.dbo.sp_add_jobschedule
@job_name = N'CommandLog Cleanup',      -- Job name
@name = N'CommandLog Cleanup',          -- Schedule name
@freq_type = 8,                            -- Weekly
@freq_interval = 1,                        -- Sunday
@freq_recurrence_factor = 1,            -- every week
@active_start_time = 100;                -- 12:01 AM


-- Add schedule for Output File Cleanup job
EXEC msdb.dbo.sp_add_jobschedule
@job_name = N'Output File Cleanup',     -- Job name
@name = N'Output File Cleanup',         -- Schedule name
@freq_type = 8,                            -- Weekly
@freq_interval = 1,                        -- Sunday
@freq_recurrence_factor = 1,            -- every week
@active_start_time = 200;                -- 12:02 AM


-- Add schedule for sp_delete_backuphistory job
EXEC msdb.dbo.sp_add_jobschedule
@job_name = N'sp_delete_backuphistory', -- Job name
@name = N'sp_delete_backuphistory',     -- Schedule name
@freq_type = 8,                            -- Weekly
@freq_interval = 1,                        -- Sunday
@freq_recurrence_factor = 1,            -- every week
@active_start_time = 300;                -- 12:03 AM


-- Add schedule for sp_purge_jobhistory job
EXEC msdb.dbo.sp_add_jobschedule
@job_name = N'sp_purge_jobhistory',     -- Job name
@name = N'sp_purge_jobhistory',         -- Schedule name
@freq_type = 8,                            -- Weekly
@freq_interval = 1,                        -- Sunday
@freq_recurrence_factor = 1,            -- every week
@active_start_time = 400;                -- 12:04 AM




-- System Database jobs *******************************


-- Add schedule for DatabaseBackup - SYSTEM_DATABASES - FULL job
EXEC msdb.dbo.sp_add_jobschedule
@job_name = N'DatabaseBackup - SYSTEM_DATABASES - FULL',        -- Job name
@name = N'DatabaseBackup - SYSTEM_DATABASES - FULL',            -- Schedule name
@freq_type = 4,                                                    -- Daily
@freq_interval = 1,                                                -- Daily
@active_start_time = 500;                                        -- 12:05 AM




-- Add schedule for DatabaseIntegrityCheck - SYSTEM_DATABASES job
EXEC msdb.dbo.sp_add_jobschedule
@job_name = N'DatabaseIntegrityCheck - SYSTEM_DATABASES',        -- Job name
@name = N'DatabaseIntegrityCheck - SYSTEM_DATABASES',            -- Schedule name
@freq_type = 4,                                                    -- Daily
@freq_interval = 1,                                                -- Daily
@active_start_time = 1000;                                        -- 12:10 AM




-- User Database jobs *******************************
-- Adjust the schedules and frequency to meet your business and infrastructure requirements


-- Add schedule for IndexOptimize - USER_DATABASES job
EXEC msdb.dbo.sp_add_jobschedule
@job_name = N'IndexOptimize - USER_DATABASES',                    -- Job name
@name = N'IndexOptimize - USER_DATABASES',                        -- Schedule name
@freq_type = 4,                                                    -- Daily
@freq_interval = 1,                                                -- Daily
@active_start_time = 10000;                                        -- 1:00 AM




-- Add schedule for DatabaseIntegrityCheck - USER_DATABASES job
EXEC msdb.dbo.sp_add_jobschedule
@job_name = N'DatabaseIntegrityCheck - USER_DATABASES',            -- Job name
@name = N'DatabaseIntegrityCheck - USER_DATABASES',                -- Schedule name
@freq_type = 4,                                                    -- Daily
@freq_interval = 1,                                                -- Daily
@active_start_time = 20000;                                        -- 2:00 AM




-- Add schedule for DatabaseBackup - USER_DATABASES - FULL job
EXEC msdb.dbo.sp_add_jobschedule
@job_name = N'DatabaseBackup - USER_DATABASES - FULL',            -- Job name
@name = N'DatabaseBackup - USER_DATABASES - FULL',                -- Schedule name
@freq_type = 4,                                                    -- Daily
@freq_interval = 1,                                                -- Daily
@active_start_time = 30000;                                        -- 3:00 AM




-- Add schedule for DatabaseBackup - USER_DATABASES - DIFF job
EXEC msdb.dbo.sp_add_jobschedule
@job_name = N'DatabaseBackup - USER_DATABASES - DIFF',            -- Job name
@name = N'DatabaseBackup - USER_DATABASES - DIFF',                -- Schedule name
@freq_type = 4,                                                    -- Daily
@freq_interval = 1,                                                -- Daily
@active_start_time = 150000;                                    -- 3:00 PM




-- Add schedule for DatabaseBackup - USER_DATABASES - LOG job
EXEC msdb.dbo.sp_add_jobschedule
@job_name = N'DatabaseBackup - USER_DATABASES - LOG',            -- Job name
@name = N'DatabaseBackup - USER_DATABASES - LOG',                -- Schedule name
@freq_type = 4,                                                    -- Daily
@freq_interval = 1,                                                -- Daily
@freq_subday_type = 4,                                            -- Minutes
@freq_subday_interval = 5;                                        -- Every 5 minutes
