/*
Script  : job-steps-search.sql
Purpose : Searches every Agent job step's command for a keyword. Useful for
          impact assessments, for example "which jobs use PowerShell remoting
          (Invoke-Command, Enter-PSSession, winrs)", "which jobs call xp_cmdshell",
          or "which jobs reference the old SMTP server or a file share".
Usage   : Edit the patterns in @Patterns. Matching is a simple LIKE.
Changes : Read-only.
Requires: SQL Server 2016 and later.
*/
DECLARE @Patterns TABLE (pattern nvarchar(200));
INSERT INTO @Patterns (pattern) VALUES
    (N'%Invoke-Command%'), (N'%PSSession%'), (N'%winrs%'), (N'%.ps1%'),
    (N'%xp_cmdshell%');

SELECT
    j.name          AS job_name,
    j.enabled,
    s.step_id,
    s.step_name,
    s.subsystem,                 -- TSQL, PowerShell, CmdExec, SSIS ...
    p.pattern       AS matched,
    s.database_name,
    s.proxy_id,
    s.command
FROM msdb.dbo.sysjobs AS j
JOIN msdb.dbo.sysjobsteps AS s ON s.job_id = j.job_id
JOIN @Patterns AS p ON s.command LIKE p.pattern
ORDER BY j.name, s.step_id;
