/*
Script  : orphaned-users-drop.sql
Purpose : Drops orphaned users in the current database (users whose SID has no
          matching login). Use after confirming the users are no longer needed.
Usage   : USE the database. Run with @Execute = 0 first and review the list.
          Set @Execute = 1 to drop. A user that owns a schema cannot be dropped
          until the schema is transferred, so those are reported as failures.
Changes : Drops database users when @Execute = 1. Script out permissions first
          (script-out-database-users-and-permissions.sql) if you might need them back.
Requires: SQL Server 2016 and later.
*/
SET NOCOUNT ON;

DECLARE @Execute bit = 0;   -- 0 = print only, 1 = drop

DECLARE @userName sysname, @sql nvarchar(4000);

DECLARE orphanedUsers CURSOR LOCAL FAST_FORWARD FOR
    SELECT dp.name
    FROM sys.database_principals AS dp
    LEFT JOIN sys.server_principals AS sp ON sp.sid = dp.sid
    WHERE sp.sid IS NULL
      AND dp.type IN ('S', 'U', 'G')
      AND dp.principal_id > 4
      AND dp.authentication_type IN (1, 3)    -- skip WITHOUT LOGIN and contained users
    ORDER BY dp.name;

OPEN orphanedUsers;
FETCH NEXT FROM orphanedUsers INTO @userName;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'DROP USER ' + QUOTENAME(@userName) + N';';
    PRINT @sql;

    IF @Execute = 1
    BEGIN
        BEGIN TRY
            EXEC sys.sp_executesql @sql;
        END TRY
        BEGIN CATCH
            PRINT N'   FAILED: ' + @userName + N' - ' + ERROR_MESSAGE();
        END CATCH;
    END;

    FETCH NEXT FROM orphanedUsers INTO @userName;
END;

CLOSE orphanedUsers;
DEALLOCATE orphanedUsers;
