/*
Script  : script-out-all-logins-roles-and-users.sql
Purpose : One pass over the whole instance that returns a script of:
            1. CREATE LOGIN for SQL logins (hashed password + SID) and Windows logins
            2. Server role membership
            3. For every online user database, CREATE USER and role membership
          Good for building a new replica or documenting access before a migration.
Usage   : Run on the source server, copy the stmt column (results to text or grid),
          review it, and run it on the target.
Changes : Read-only. Output contains password hashes, so treat it as sensitive.
Requires: SQL Server 2016 and later.
Source  : Based on a script by Greg Ryan (2013). Fixed the IF NOT EXISTS checks,
          which compared against bracketed names and so never matched, quoted
          database names, removed PRINT truncation, and replaced deprecated
          catalog views.
*/
SET NOCOUNT ON;

IF OBJECT_ID(N'tempdb..#out') IS NOT NULL DROP TABLE #out;
CREATE TABLE #out (id int IDENTITY, section tinyint, db sysname NULL, stmt nvarchar(max));

-- 1. Logins
INSERT INTO #out (section, stmt)
SELECT 1,
       N'IF NOT EXISTS (SELECT * FROM sys.server_principals WHERE name = N''' + REPLACE(name, N'''', N'''''') + N''') '
     + N'CREATE LOGIN ' + QUOTENAME(name)
     + N' WITH PASSWORD = ' + CONVERT(nvarchar(max), password_hash, 1) + N' HASHED'
     + N', SID = ' + CONVERT(nvarchar(max), sid, 1)
     + N', DEFAULT_DATABASE = ' + QUOTENAME(COALESCE(default_database_name, N'master'))
     + N', DEFAULT_LANGUAGE = ' + QUOTENAME(COALESCE(default_language_name, N'us_english'))
     + N', CHECK_EXPIRATION = ' + CASE is_expiration_checked WHEN 1 THEN N'ON' ELSE N'OFF' END
     + N', CHECK_POLICY = '     + CASE is_policy_checked     WHEN 1 THEN N'ON' ELSE N'OFF' END + N';'
FROM sys.sql_logins
WHERE name <> N'sa'
  AND name NOT LIKE N'##%';

INSERT INTO #out (section, stmt)
SELECT 1,
       N'IF NOT EXISTS (SELECT * FROM sys.server_principals WHERE name = N''' + REPLACE(name, N'''', N'''''') + N''') '
     + N'CREATE LOGIN ' + QUOTENAME(name) + N' FROM WINDOWS WITH DEFAULT_DATABASE = '
     + QUOTENAME(COALESCE(default_database_name, N'master'))
     + N', DEFAULT_LANGUAGE = ' + QUOTENAME(COALESCE(default_language_name, N'us_english')) + N';'
FROM sys.server_principals
WHERE type IN ('U', 'G')
  AND name NOT LIKE N'NT SERVICE\%'
  AND name NOT LIKE N'NT AUTHORITY\%'
  AND name <> N'BUILTIN\Administrators';

-- 2. Server role membership
INSERT INTO #out (section, stmt)
SELECT 2, N'ALTER SERVER ROLE ' + QUOTENAME(r.name) + N' ADD MEMBER ' + QUOTENAME(l.name) + N';'
FROM sys.server_role_members AS rm
JOIN sys.server_principals AS l ON l.principal_id = rm.member_principal_id
JOIN sys.server_principals AS r ON r.principal_id = rm.role_principal_id
WHERE l.type IN ('U', 'G', 'S')
  AND l.name NOT IN (N'sa', N'BUILTIN\Administrators')
  AND l.name NOT LIKE N'NT SERVICE\%'
  AND l.name NOT LIKE N'NT AUTHORITY\%';

-- 3. Users and role membership in each user database.
--    The inner batch runs in each database through <db>.sys.sp_executesql.
DECLARE @inner nvarchar(max) = N'
INSERT INTO #out (section, db, stmt)
SELECT 3, DB_NAME(),
       N''IF DATABASE_PRINCIPAL_ID(N'''''' + REPLACE(dp.name, N'''''''', N'''''''''''') + N'''''') IS NULL CREATE USER ''
     + QUOTENAME(dp.name) + ISNULL(N'' FOR LOGIN '' + QUOTENAME(sp.name), N'''') + N'';''
FROM sys.database_principals AS dp
LEFT JOIN sys.server_principals AS sp ON sp.sid = dp.sid
WHERE dp.type IN (''S'', ''U'', ''G'')
  AND dp.principal_id > 4;

INSERT INTO #out (section, db, stmt)
SELECT 4, DB_NAME(), N''ALTER ROLE '' + QUOTENAME(r.name) + N'' ADD MEMBER '' + QUOTENAME(m.name) + N'';''
FROM sys.database_role_members AS rm
JOIN sys.database_principals AS r ON r.principal_id = rm.role_principal_id
JOIN sys.database_principals AS m ON m.principal_id = rm.member_principal_id
WHERE m.principal_id > 4;';

DECLARE @db sysname, @proc nvarchar(300);

DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases
    WHERE database_id > 4 AND state_desc = N'ONLINE'
    ORDER BY name;

OPEN db_cur;
FETCH NEXT FROM db_cur INTO @db;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @proc = QUOTENAME(@db) + N'.sys.sp_executesql';
    BEGIN TRY
        EXEC @proc @inner;
    END TRY
    BEGIN CATCH
        INSERT INTO #out (section, db, stmt) VALUES (3, @db, N'-- skipped: ' + ERROR_MESSAGE());
    END CATCH;
    FETCH NEXT FROM db_cur INTO @db;
END;
CLOSE db_cur;
DEALLOCATE db_cur;

-- Output: logins, then server roles, then one block per database with its USE line
SELECT stmt
FROM (
    SELECT section, CAST(N'' AS nvarchar(128)) AS db, 0 AS ord, id, stmt FROM #out WHERE section IN (1, 2)
    UNION ALL
    SELECT DISTINCT 3, db, -1, 0, N'USE ' + QUOTENAME(db) + N';' FROM #out WHERE section IN (3, 4)
    UNION ALL
    SELECT 3, db, section, id, stmt FROM #out WHERE section IN (3, 4)
) AS x
ORDER BY CASE WHEN x.section < 3 THEN x.section ELSE 3 END, x.db, x.ord, x.id;

DROP TABLE #out;
