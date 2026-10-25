/*
Script  : failed-logins-and-locked-accounts.sql
Purpose : Troubleshoots "Login failed" and locked-out SQL logins.
            1. Recent failed logins from the default trace (who, from which host and app)
            2. Failed logins from the SQL Server error log (includes the reason/state)
            3. Lock-out and password policy status for one login
            4. Unlock commands (commented out)
Usage   : Set @LoginName for sections 3 and 4.
          Error 18456 state codes: 5 = login does not exist, 8 = wrong password,
          38 = database in the connection string not found or no access,
          18488/18487 = password expired / must change.
Changes : Read-only. Section 4 changes the login only if you uncomment it.
Requires: SQL Server 2016 and later. Default trace must be enabled for section 1.
*/
SET NOCOUNT ON;

DECLARE @LoginName sysname = N'YourLoginName';

-- 1. Default trace: Audit Login Failed events
DECLARE @path nvarchar(260);
SELECT @path = REVERSE(SUBSTRING(REVERSE(path), CHARINDEX(N'\', REVERSE(path)), 260)) + N'log.trc'
FROM sys.traces
WHERE is_default = 1;

IF @path IS NULL
    PRINT N'Default trace is not enabled; use section 2.';
ELSE
    SELECT TOP (50)
        t.StartTime,
        t.LoginName,
        t.NTDomainName,
        t.NTUserName,
        t.HostName,
        t.ApplicationName,
        t.DatabaseName,
        t.TextData            -- includes the 18456 message
    FROM sys.fn_trace_gettable(@path, DEFAULT) AS t
    JOIN sys.trace_events AS te ON te.trace_event_id = t.EventClass
    WHERE te.name = N'Audit Login Failed'
    ORDER BY t.StartTime DESC;

-- 2. Error log: failed logins in the current log (0 = current, 1 = previous, ...)
EXEC master.dbo.xp_readerrorlog 0, 1, N'Login failed';

-- 3. Lock-out and policy status
SELECT
    name,
    is_disabled,
    is_policy_checked,
    is_expiration_checked,
    LOGINPROPERTY(name, 'IsLocked')            AS is_locked,
    LOGINPROPERTY(name, 'IsExpired')           AS is_expired,
    LOGINPROPERTY(name, 'IsMustChange')        AS must_change,
    LOGINPROPERTY(name, 'BadPasswordCount')    AS bad_password_count,
    LOGINPROPERTY(name, 'BadPasswordTime')     AS last_bad_password,
    LOGINPROPERTY(name, 'LockoutTime')         AS lockout_time,
    LOGINPROPERTY(name, 'PasswordLastSetTime') AS password_last_set
FROM sys.sql_logins
WHERE name = @LoginName;

/* 4. Unlock (pick one). Confirm with the account owner first, and find what is
      sending the bad password (section 1 HostName/ApplicationName) or it will
      lock again.

-- Unlock without changing the password (requires the current password)
ALTER LOGIN [YourLoginName] WITH PASSWORD = N'CurrentPassword' UNLOCK;

-- Reset the password and unlock
ALTER LOGIN [YourLoginName] WITH PASSWORD = N'NewStrongPassword' UNLOCK;

-- Last resort: turn the policy off and back on, which clears the lock-out
ALTER LOGIN [YourLoginName] WITH CHECK_POLICY = OFF;
ALTER LOGIN [YourLoginName] WITH CHECK_POLICY = ON;
*/
