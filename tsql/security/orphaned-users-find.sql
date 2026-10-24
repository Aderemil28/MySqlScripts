/*
Script  : orphaned-users-find.sql
Purpose : Lists orphaned users, meaning database users whose SID has no matching
          login on this instance. Typical after a restore from another server or
          an AG failover where logins were not synced.
          Section 1 checks the current database. Section 2 checks every database.
          The match_by_name column shows whether a login with the same name
          exists (fix with ALTER USER ... WITH LOGIN) or not (create the login,
          or drop the user).
Usage   : Run as is. Then use orphaned-users-fix.sql or orphaned-users-drop.sql.
Changes : Read-only.
Requires: SQL Server 2016 and later.
*/
SET NOCOUNT ON;

-- 1. Current database
SELECT
    DB_NAME()                     AS database_name,
    dp.name                       AS user_name,
    dp.type_desc,
    dp.authentication_type_desc,
    dp.create_date,
    CASE WHEN sp2.name IS NOT NULL THEN 'Login with same name exists'
         ELSE 'No login with this name' END AS match_by_name
FROM sys.database_principals AS dp
LEFT JOIN sys.server_principals AS sp  ON sp.sid   = dp.sid
LEFT JOIN sys.server_principals AS sp2 ON sp2.name = dp.name COLLATE DATABASE_DEFAULT
WHERE dp.type IN ('S', 'U', 'G')            -- SQL user, Windows user, Windows group
  AND dp.principal_id > 4                   -- skip dbo, guest, INFORMATION_SCHEMA, sys
  AND dp.authentication_type IN (1, 3)      -- 1 = instance (SQL login), 3 = Windows; skips WITHOUT LOGIN and contained users
  AND sp.sid IS NULL
ORDER BY dp.name;

-- 2. All online databases
IF OBJECT_ID(N'tempdb..#orphans') IS NOT NULL DROP TABLE #orphans;
CREATE TABLE #orphans (database_name sysname, user_name sysname, type_desc nvarchar(60), authentication_type_desc nvarchar(60));

DECLARE @inner nvarchar(max) = N'
INSERT INTO #orphans
SELECT DB_NAME(), dp.name, dp.type_desc, dp.authentication_type_desc
FROM sys.database_principals AS dp
LEFT JOIN sys.server_principals AS sp ON sp.sid = dp.sid
WHERE dp.type IN (''S'', ''U'', ''G'')
  AND dp.principal_id > 4
  AND dp.authentication_type IN (1, 3)
  AND sp.sid IS NULL;';

DECLARE @db sysname, @proc nvarchar(300);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases WHERE state_desc = N'ONLINE' AND database_id <> 2 ORDER BY name;
OPEN c;
FETCH NEXT FROM c INTO @db;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @proc = QUOTENAME(@db) + N'.sys.sp_executesql';
    BEGIN TRY EXEC @proc @inner; END TRY BEGIN CATCH PRINT @db + N': ' + ERROR_MESSAGE(); END CATCH;
    FETCH NEXT FROM c INTO @db;
END;
CLOSE c;
DEALLOCATE c;

SELECT * FROM #orphans ORDER BY database_name, user_name;
DROP TABLE #orphans;
