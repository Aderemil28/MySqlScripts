/*
Script  : sql-login-policy-audit.sql
Purpose : Security audit findings for SQL-authenticated logins and one server
          setting, each row a finding you can put straight into an audit
          response:
            1. Enabled sysadmin SQL logins whose password never expires
            2. Enabled SQL logins that ignore the Windows password policy
            3. The "remote access" server setting (should be 0)
          For a full list of every login and its settings, use logins-overview.sql.
Usage   : Run as is. No rows in 1 and 2 means no findings.
          Before changing a login, check what uses it: service and application
          logins often have policy or expiry off on purpose, and turning
          expiry on can lock an application out when the password ages.
Changes : Read-only. The fix commands at the end are commented out.
Requires: SQL Server 2016 and later.
*/

-- 1. Enabled sysadmin SQL logins with no password expiry
SELECT  N'1. sysadmin, password never expires'          AS finding,
        l.name                                          AS login_name,
        l.is_policy_checked,
        l.is_expiration_checked,
        LOGINPROPERTY(l.name, 'PasswordLastSetTime')    AS password_last_set,
        LOGINPROPERTY(l.name, 'DaysUntilExpiration')    AS days_until_expiration
FROM sys.sql_logins AS l
JOIN sys.server_role_members AS rm ON rm.member_principal_id = l.principal_id
JOIN sys.server_principals  AS r  ON r.principal_id = rm.role_principal_id
WHERE r.name = N'sysadmin'
  AND l.is_expiration_checked = 0
  AND l.is_disabled = 0
  AND l.name NOT LIKE N'##%'
ORDER BY l.name;

-- 2. Enabled SQL logins with the password policy off
SELECT  N'2. password policy off'                       AS finding,
        l.name                                          AS login_name,
        l.is_policy_checked,
        l.is_expiration_checked,
        LOGINPROPERTY(l.name, 'PasswordLastSetTime')    AS password_last_set,
        IS_SRVROLEMEMBER(N'sysadmin', l.name)           AS is_sysadmin
FROM sys.sql_logins AS l
WHERE l.is_policy_checked = 0
  AND l.is_disabled = 0
  AND l.name NOT LIKE N'##%'
ORDER BY l.name;

-- 3. "remote access" lets other servers run procedures here through the old
--    remote server feature. It is deprecated; it should be 0 unless something
--    still depends on it. (Linked servers do not need it.)
SELECT  N'3. remote access setting'                     AS finding,
        name, value, value_in_use, description,
        CASE WHEN value_in_use = 0 THEN 'OK' ELSE 'REVIEW' END AS status
FROM sys.configurations
WHERE name = N'remote access';

-- Fixes (after checking with the login's owner):
-- ALTER LOGIN [login_name] WITH CHECK_POLICY = ON;
-- ALTER LOGIN [login_name] WITH CHECK_EXPIRATION = ON;      -- needs CHECK_POLICY = ON
-- EXEC sp_configure 'remote access', 0; RECONFIGURE;         -- takes effect after a service restart
