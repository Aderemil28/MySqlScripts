/*
Script  : database-users-and-roles-all-databases.sql
Purpose : Every user in every online database with its role memberships and
          mapped login. Useful for access reviews and audit requests.
Usage   : Run as is. Filter the final SELECT if you only need one login.
Changes : Read-only.
Requires: SQL Server 2016 and later.
*/
SET NOCOUNT ON;

IF OBJECT_ID(N'tempdb..#users') IS NOT NULL DROP TABLE #users;
CREATE TABLE #users
(
    server_name         sysname,
    database_name       sysname,
    user_name           sysname,
    user_type           nvarchar(60),
    role_name           sysname NULL,
    login_name          sysname NULL,
    default_schema_name sysname NULL
);

DECLARE @inner nvarchar(max) = N'
INSERT INTO #users
SELECT @@SERVERNAME, DB_NAME(), u.name, u.type_desc,
       ISNULL(r.name, ''public''), l.name, u.default_schema_name
FROM sys.database_principals AS u
LEFT JOIN sys.database_role_members AS m ON m.member_principal_id = u.principal_id
LEFT JOIN sys.database_principals   AS r ON r.principal_id = m.role_principal_id
LEFT JOIN sys.server_principals     AS l ON l.sid = u.sid
WHERE u.type IN (''S'', ''U'', ''G'', ''E'', ''X'')
  AND u.principal_id > 4;';

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

SELECT *
FROM #users
-- WHERE login_name = N'DOMAIN\SomeUser'
ORDER BY database_name, user_name, role_name;

DROP TABLE #users;
