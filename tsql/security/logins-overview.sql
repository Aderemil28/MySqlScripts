/*
Script  : logins-overview.sql
Purpose : Server-level view of logins: type, enabled or disabled, password
          policy settings, default database, and server role membership.
Usage   : Run as is.
Changes : Read-only.
Requires: SQL Server 2016 and later.
*/
SELECT
    sp.name                                              AS login_name,
    sp.type_desc                                         AS login_type,
    CASE WHEN sp.is_disabled = 1 THEN 'Disabled' ELSE 'Enabled' END AS status,
    sp.default_database_name,
    sl.is_policy_checked,
    sl.is_expiration_checked,
    LOGINPROPERTY(sp.name, 'PasswordLastSetTime')        AS password_last_set,
    LOGINPROPERTY(sp.name, 'IsLocked')                   AS is_locked,
    sp.create_date,
    sp.modify_date,
    STUFF((SELECT N', ' + r.name
           FROM sys.server_role_members AS rm
           JOIN sys.server_principals AS r ON r.principal_id = rm.role_principal_id
           WHERE rm.member_principal_id = sp.principal_id
           FOR XML PATH('')), 1, 2, N'')                 AS server_roles
FROM sys.server_principals AS sp
LEFT JOIN sys.sql_logins AS sl ON sl.principal_id = sp.principal_id
WHERE sp.type IN ('S', 'U', 'G')            -- SQL login, Windows login, Windows group
  AND sp.name NOT LIKE N'##%'
ORDER BY sp.name;
