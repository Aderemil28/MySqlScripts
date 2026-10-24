/*
Script  : orphaned-users-fix.sql
Purpose : Re-maps orphaned users in the current database to the login with the
          same name (ALTER USER ... WITH LOGIN). Replaces the deprecated
          sp_change_users_login 'Auto_Fix'.
Usage   : USE the database, run with @Execute = 0 to review, then @Execute = 1.
          Users with no matching login are listed but not changed. Create the
          login first (ideally with the original SID, see
          script-out-logins-sp_help_revlogin.sql) or drop the user.
Changes : Alters database users when @Execute = 1.
Requires: SQL Server 2016 and later.
*/
SET NOCOUNT ON;

DECLARE @Execute bit = 0;   -- 0 = print only, 1 = run

DECLARE @user sysname, @login sysname, @sql nvarchar(max);

DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT dp.name, sp2.name
    FROM sys.database_principals AS dp
    LEFT JOIN sys.server_principals AS sp  ON sp.sid   = dp.sid
    LEFT JOIN sys.server_principals AS sp2 ON sp2.name = dp.name COLLATE DATABASE_DEFAULT
                                          AND sp2.type IN ('S', 'U', 'G')
    WHERE dp.type IN ('S', 'U', 'G')
      AND dp.principal_id > 4
      AND dp.authentication_type IN (1, 3)
      AND sp.sid IS NULL
    ORDER BY dp.name;

OPEN c;
FETCH NEXT FROM c INTO @user, @login;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF @login IS NULL
        PRINT N'-- No login named ' + QUOTENAME(@user) + N'. Create it first or drop the user.';
    ELSE
    BEGIN
        SET @sql = N'ALTER USER ' + QUOTENAME(@user) + N' WITH LOGIN = ' + QUOTENAME(@login) + N';';
        PRINT @sql;
        IF @Execute = 1
        BEGIN
            BEGIN TRY EXEC sys.sp_executesql @sql; END TRY
            BEGIN CATCH PRINT N'   FAILED: ' + ERROR_MESSAGE(); END CATCH;
        END;
    END;
    FETCH NEXT FROM c INTO @user, @login;
END;
CLOSE c;
DEALLOCATE c;
