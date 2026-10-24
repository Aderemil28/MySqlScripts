/*
Script  : jobs-schedule-and-next-run.sql
Purpose : Every Agent job with owner, category, enabled flags, schedule and the
          next scheduled run as a real datetime, plus the last run outcome.
Usage   : Run as is. Set @EnabledOnly = 0 to include disabled jobs.
Changes : Read-only.
Requires: SQL Server 2016 and later.
*/
DECLARE @EnabledOnly bit = 1;

SELECT
    j.name                                    AS job_name,
    SUSER_SNAME(j.owner_sid)                  AS job_owner,
    c.name                                    AS category_name,
    j.enabled                                 AS job_enabled,
    s.name                                    AS schedule_name,
    s.enabled                                 AS schedule_enabled,
    CASE WHEN js.next_run_date > 0
         THEN msdb.dbo.agent_datetime(js.next_run_date, js.next_run_time) END AS next_run,
    CASE WHEN jh.run_date IS NOT NULL
         THEN msdb.dbo.agent_datetime(jh.run_date, jh.run_time) END           AS last_run,
    CASE jh.run_status WHEN 0 THEN 'Failed' WHEN 1 THEN 'Succeeded' WHEN 2 THEN 'Retry'
                       WHEN 3 THEN 'Canceled' WHEN 4 THEN 'In progress' END AS last_outcome,
    j.notify_level_email,
    o.name                                    AS notify_operator,
    j.description
FROM msdb.dbo.sysjobs AS j
JOIN msdb.dbo.syscategories AS c ON c.category_id = j.category_id
LEFT JOIN msdb.dbo.sysjobschedules AS js ON js.job_id = j.job_id
LEFT JOIN msdb.dbo.sysschedules    AS s  ON s.schedule_id = js.schedule_id
LEFT JOIN msdb.dbo.sysoperators    AS o  ON o.id = j.notify_email_operator_id
OUTER APPLY (SELECT TOP (1) h.run_date, h.run_time, h.run_status
             FROM msdb.dbo.sysjobhistory AS h
             WHERE h.job_id = j.job_id AND h.step_id = 0
             ORDER BY h.instance_id DESC) AS jh
WHERE @EnabledOnly = 0 OR j.enabled = 1
ORDER BY j.name, s.name;
