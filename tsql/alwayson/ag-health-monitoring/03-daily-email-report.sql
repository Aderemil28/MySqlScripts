/*
Script  : 03-daily-email-report.sql  (AG health monitoring, step 3 of 3, optional)
Purpose : Agent job that emails a daily AG health summary at 08:00. The body
          lists anything not HEALTHY in the last 24 hours, plus the latest
          snapshot, and attaches the full day's rows as a text file.
Usage   : Database Mail must be configured. Set @Profile and @Recipients.
          Find your profile name with tsql/monitoring/database-mail-check.sql.
Changes : Creates an Agent job in msdb.
Requires: SQL Server 2017 and later (STRING_AGG). On 2016 replace STRING_AGG
          with FOR XML PATH concatenation.
Fixes vs the original notes:
          - STRING_AGG input is cast to nvarchar(max); without it the result is
            capped at 8000 bytes and the job fails once the table has a day of rows
          - unhealthy rows are called out first instead of a plain dump
*/
USE msdb;
GO

DECLARE @Profile    sysname       = N'YourMailProfile';
DECLARE @Recipients nvarchar(400) = N'dba-team@example.com';
DECLARE @Owner      sysname       = SUSER_SNAME(0x01);

DECLARE @cmd nvarchar(max) = N'
DECLARE @body nvarchar(max), @issues nvarchar(max), @latest nvarchar(max);

SELECT @issues = STRING_AGG(CAST(CONVERT(nvarchar(16), LoggedAt, 120) + N''  '' + AGName + N''  ''
                + ReplicaServerName + N''  '' + ISNULL(DatabaseName, N''-'') + N''  ''
                + ISNULL(SyncState, N''-'') + N''/'' + ISNULL(SyncHealth, N''-'') AS nvarchar(max)), CHAR(13) + CHAR(10))
FROM DBAUtil.dbo.AGHealthStatus
WHERE LoggedAt >= DATEADD(HOUR, -24, GETDATE())
  AND (SyncHealth <> N''HEALTHY'' OR IsSuspended = 1);

SELECT @latest = STRING_AGG(CAST(AGName + N''  '' + ReplicaServerName + N''  '' + ISNULL(DatabaseName, N''-'')
                + N''  '' + ISNULL(SyncState, N''-'') + N''  lag(s): '' + ISNULL(CAST(SecondaryLagSeconds AS nvarchar(20)), N''-'') AS nvarchar(max)),
                CHAR(13) + CHAR(10))
FROM DBAUtil.dbo.AGHealthStatus
WHERE LoggedAt = (SELECT MAX(LoggedAt) FROM DBAUtil.dbo.AGHealthStatus);

SET @body = N''Unhealthy or suspended in the last 24 hours:'' + CHAR(13) + CHAR(10)
          + ISNULL(@issues, N''None'') + CHAR(13) + CHAR(10) + CHAR(13) + CHAR(10)
          + N''Latest snapshot:'' + CHAR(13) + CHAR(10) + ISNULL(@latest, N''No data collected'');

EXEC msdb.dbo.sp_send_dbmail
     @profile_name = N''' + REPLACE(@Profile, N'''', N'''''') + N''',
     @recipients   = N''' + REPLACE(@Recipients, N'''', N'''''') + N''',
     @subject      = N''AG health daily report - ' + REPLACE(@@SERVERNAME, N'''', N'''''') + N''',
     @body         = @body,
     @query        = N''SELECT LoggedAt, AGName, ReplicaServerName, ReplicaRole, DatabaseName, SyncState, SyncHealth, IsSuspended, LogSendQueueKB, RedoQueueKB, SecondaryLagSeconds FROM DBAUtil.dbo.AGHealthStatus WHERE LoggedAt >= DATEADD(HOUR, -24, GETDATE()) ORDER BY LoggedAt, AGName, ReplicaServerName'',
     @attach_query_result_as_file = 1,
     @query_attachment_filename   = N''AGHealthLast24h.txt'',
     @query_result_width          = 400;';

IF NOT EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name = N'DBA - AG Health Daily Email')
BEGIN
    EXEC dbo.sp_add_job         @job_name = N'DBA - AG Health Daily Email',
                                @description = N'Emails the AG health summary from DBAUtil.dbo.AGHealthStatus',
                                @owner_login_name = @Owner;
    EXEC dbo.sp_add_jobstep     @job_name = N'DBA - AG Health Daily Email',
                                @step_name = N'Send report',
                                @subsystem = N'TSQL',
                                @database_name = N'msdb',
                                @command = @cmd;
    EXEC dbo.sp_add_jobschedule @job_name = N'DBA - AG Health Daily Email',
                                @name = N'Daily 08:00 - AG health email',
                                @freq_type = 4, @freq_interval = 1,
                                @active_start_time = 80000;                 -- 08:00:00
    EXEC dbo.sp_add_jobserver   @job_name = N'DBA - AG Health Daily Email';
END;
GO

-- Test
-- EXEC msdb.dbo.sp_start_job @job_name = N'DBA - AG Health Daily Email';
-- SELECT TOP (5) sent_status, send_request_date, subject FROM msdb.dbo.sysmail_allitems ORDER BY send_request_date DESC;
