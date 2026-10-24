/*
Script  : database-mail-check.sql
Purpose : Database Mail troubleshooting in one place:
            1. Profiles, accounts and the SMTP server each one uses
            2. Send a test email
            3. Recent mail items and their status
            4. Recent Database Mail errors
Usage   : Run section 1 to find the profile name, set @Profile and @To,
          run section 2, wait 10 seconds, then sections 3 and 4.
          Runs from any database (everything is msdb-qualified).
Changes : Section 2 sends an email. Everything else is read-only.
Requires: SQL Server 2016 and later.
*/

-- 1. Profiles and SMTP servers
SELECT p.name AS profile_name, a.name AS account_name, a.email_address,
       s.servername AS smtp_server, s.port, s.enable_ssl, pa.sequence_number
FROM msdb.dbo.sysmail_profile AS p
JOIN msdb.dbo.sysmail_profileaccount AS pa ON pa.profile_id = p.profile_id
JOIN msdb.dbo.sysmail_account        AS a  ON a.account_id  = pa.account_id
JOIN msdb.dbo.sysmail_server         AS s  ON s.account_id  = a.account_id
ORDER BY p.name, pa.sequence_number;

-- 2. Test email (uncomment to send)
DECLARE @Profile sysname       = N'YourMailProfile';
DECLARE @To      nvarchar(400) = N'you@example.com';
/*
DECLARE @subj nvarchar(255) = N'Database Mail test from ' + @@SERVERNAME;
EXEC msdb.dbo.sp_send_dbmail
     @profile_name = @Profile,
     @recipients   = @To,
     @subject      = @subj,
     @body         = N'Test email. If you can read this, Database Mail works.';
*/

-- 3. Recent mail items: sent, unsent, retrying or failed
SELECT TOP (20) mailitem_id, sent_status, send_request_date, sent_date, recipients, subject
FROM msdb.dbo.sysmail_allitems
ORDER BY send_request_date DESC;

-- 4. Recent errors
SELECT TOP (20) l.log_date, l.event_type, l.description, i.recipients, i.subject
FROM msdb.dbo.sysmail_event_log AS l
LEFT JOIN msdb.dbo.sysmail_allitems AS i ON i.mailitem_id = l.mailitem_id
WHERE l.event_type IN (N'error', N'warning')
ORDER BY l.log_date DESC;
