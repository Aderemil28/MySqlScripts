/*
Script  : script-out-database-users-and-permissions.sql
Purpose : Generates a re-runnable script of the current database's users, role
          membership, user-defined roles, and object, schema and database level
          permissions. Run it before a refresh or restore over an existing
          database so you can put the target's access back afterwards.
Usage   : USE the database first, run, then copy the printed output.
          The generated statements use IF NOT EXISTS / IF ... IS NOT NULL
          guards so they are safe to run more than once.
Changes : Read-only. Output is text only.
Requires: SQL Server 2016 and later.
Source  : Based on a DBA Stack Exchange answer (question 190475), cleaned up.
*/
SET NOCOUNT ON;

DECLARE @out TABLE (sort_order decimal(5,1), stmt nvarchar(max));

INSERT INTO @out VALUES (0, N'USE ' + QUOTENAME(DB_NAME()) + N';'), (0.1, N'GO');

-- Users (skips system users and users created for certificates or keys)
INSERT INTO @out
SELECT 1,
       N'IF DATABASE_PRINCIPAL_ID(N''' + REPLACE(dp.name, N'''', N'''''') + N''') IS NULL CREATE USER ' + QUOTENAME(dp.name)
     + CASE WHEN sp.name IS NOT NULL THEN N' FOR LOGIN ' + QUOTENAME(sp.name)
            WHEN dp.type = 'S' AND dp.authentication_type = 0 THEN N' WITHOUT LOGIN'
            ELSE N'' END
     + ISNULL(N' WITH DEFAULT_SCHEMA = ' + QUOTENAME(dp.default_schema_name), N'') + N';'
FROM sys.database_principals AS dp
LEFT JOIN sys.server_principals AS sp ON sp.sid = dp.sid
WHERE dp.type IN ('S', 'U', 'G')
  AND dp.principal_id > 4;

-- User-defined database roles
INSERT INTO @out
SELECT 2, N'IF DATABASE_PRINCIPAL_ID(N''' + REPLACE(name, N'''', N'''''') + N''') IS NULL CREATE ROLE ' + QUOTENAME(name) + N';'
FROM sys.database_principals
WHERE type = 'R' AND is_fixed_role = 0 AND principal_id > 0 AND name <> N'public';

-- Role membership
INSERT INTO @out
SELECT 3, N'ALTER ROLE ' + QUOTENAME(r.name) + N' ADD MEMBER ' + QUOTENAME(m.name) + N';'
FROM sys.database_role_members AS rm
JOIN sys.database_principals AS r ON r.principal_id = rm.role_principal_id
JOIN sys.database_principals AS m ON m.principal_id = rm.member_principal_id
WHERE m.principal_id > 4;

-- Object and column level permissions
INSERT INTO @out
SELECT 4,
       CASE WHEN p.state = 'W' THEN N'GRANT' ELSE p.state_desc END + N' ' + p.permission_name
     + N' ON ' + QUOTENAME(OBJECT_SCHEMA_NAME(p.major_id)) + N'.' + QUOTENAME(OBJECT_NAME(p.major_id))
     + ISNULL(N' (' + QUOTENAME(c.name) + N')', N'')
     + N' TO ' + QUOTENAME(u.name)
     + CASE WHEN p.state = 'W' THEN N' WITH GRANT OPTION' ELSE N'' END + N';'
FROM sys.database_permissions AS p
JOIN sys.database_principals AS u ON u.principal_id = p.grantee_principal_id
LEFT JOIN sys.columns AS c ON c.object_id = p.major_id AND c.column_id = p.minor_id
WHERE p.class = 1
  AND u.principal_id > 4
  AND OBJECTPROPERTY(p.major_id, 'IsMSShipped') = 0;

-- Schema level permissions
INSERT INTO @out
SELECT 5,
       CASE WHEN p.state = 'W' THEN N'GRANT' ELSE p.state_desc END + N' ' + p.permission_name
     + N' ON SCHEMA::' + QUOTENAME(SCHEMA_NAME(p.major_id)) + N' TO ' + QUOTENAME(u.name)
     + CASE WHEN p.state = 'W' THEN N' WITH GRANT OPTION' ELSE N'' END + N';'
FROM sys.database_permissions AS p
JOIN sys.database_principals AS u ON u.principal_id = p.grantee_principal_id
WHERE p.class = 3
  AND u.principal_id > 4;

-- Database level permissions (CONNECT, VIEW DEFINITION, EXECUTE, ...)
INSERT INTO @out
SELECT 6,
       CASE WHEN p.state = 'W' THEN N'GRANT' ELSE p.state_desc END + N' ' + p.permission_name
     + N' TO ' + QUOTENAME(u.name)
     + CASE WHEN p.state = 'W' THEN N' WITH GRANT OPTION' ELSE N'' END + N';'
FROM sys.database_permissions AS p
JOIN sys.database_principals AS u ON u.principal_id = p.grantee_principal_id
WHERE p.class = 0
  AND u.principal_id > 4
  AND u.type IN ('S', 'U', 'G', 'R')
  AND NOT (p.permission_name = 'CONNECT' AND u.type = 'R');

SELECT stmt AS [-- generated script --]
FROM @out
ORDER BY sort_order, stmt;
