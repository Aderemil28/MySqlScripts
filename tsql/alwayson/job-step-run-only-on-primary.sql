/*
Script  : job-step-run-only-on-primary.sql
Purpose : First step for any Agent job that exists on every AG replica but must
          only do work on the primary (CDC capture/cleanup, ETL, purge jobs).
          On a secondary the step raises an error, so set the step's
          "On failure" action to "Quit the job reporting success" and the job
          ends quietly. On the primary it succeeds and the job moves on.
Usage   : Set @DatabaseName to an AG database the job works on, paste as step 1.
          Section 2 lists CDC jobs so you can see what to guard.
Changes : Read-only.
Requires: SQL Server 2016 and later.
*/

-- 1. Guard step
DECLARE @DatabaseName sysname = N'YourAGDatabase';

IF sys.fn_hadr_is_primary_replica(@DatabaseName) <> 1
    RAISERROR (N'Not the primary replica for %s. Skipping job.', 16, 1, @DatabaseName);

-- 2. CDC jobs for the current database (run in the CDC-enabled database)
-- EXEC sys.sp_cdc_help_jobs;
