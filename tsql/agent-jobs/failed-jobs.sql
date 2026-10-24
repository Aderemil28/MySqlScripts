/*
Script  : failed-jobs.sql
Purpose : Agent job step failures in the last N days with readable run times,
          duration and the error message.
Usage   : Set @DaysBack. Set @JobNameLike to narrow it down.
Changes : Read-only.
Requires: SQL Server 2016 and later.
*/
DECLARE @DaysBack    int           = 7;
DECLARE @JobNameLike nvarchar(128) = N'%';

SELECT
    j.name                                              AS job_name,
    h.step_id,
    h.step_name,
    msdb.dbo.agent_datetime(h.run_date, h.run_time)     AS run_datetime,
    STUFF(STUFF(RIGHT('000000' + CAST(h.run_duration AS varchar(6)), 6), 5, 0, ':'), 3, 0, ':') AS duration_hhmmss,
    h.sql_message_id,
    h.sql_severity,
    h.message                                           AS error_message,
    h.server
FROM msdb.dbo.sysjobs AS j
JOIN msdb.dbo.sysjobhistory AS h ON h.job_id = j.job_id
WHERE h.run_status = 0                                  -- 0 = failed
  AND h.step_id > 0                                     -- step rows only; step 0 is the job outcome
  AND j.name LIKE @JobNameLike
  AND msdb.dbo.agent_datetime(h.run_date, h.run_time) >= DATEADD(DAY, -@DaysBack, GETDATE())
ORDER BY run_datetime DESC;
