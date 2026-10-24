/*
Script  : script-out-logins-sp_help_revlogin.sql
Purpose : Creates sp_hexadecimal and sp_help_revlogin in master, then generates
          CREATE LOGIN statements for SQL logins (with the original password
          hash and SID) and Windows logins/groups, plus server role membership.
          Use it to move logins to a new server or keep AG replicas in sync,
          so database users do not become orphaned after a restore or failover.
Usage   : Run once to create the procedures, then:
              EXEC master.dbo.sp_help_revlogin;                     -- all logins
              EXEC master.dbo.sp_help_revlogin @login_name = N'x';  -- one login
          Copy the printed output and run it on the target server.
Changes : Creates or replaces two procedures in master. The output contains
          password hashes, so treat it as sensitive and do not save it in source control.
Requires: SQL Server 2016 and later.
Source  : Microsoft support article "Transfer logins and passwords between
          instances of SQL Server", with server role scripting added.
*/
USE [master];
GO

IF OBJECT_ID(N'dbo.sp_hexadecimal') IS NOT NULL
    DROP PROCEDURE dbo.sp_hexadecimal;
GO
CREATE PROCEDURE dbo.sp_hexadecimal
    @binvalue varbinary(256),
    @hexvalue varchar(514) OUTPUT
AS
BEGIN
    DECLARE @charvalue varchar(514) = '0x',
            @i         int          = 1,
            @length    int          = DATALENGTH(@binvalue),
            @hexstring char(16)     = '0123456789ABCDEF',
            @tempint   int,
            @firstint  int,
            @secondint int;

    WHILE (@i <= @length)
    BEGIN
        SET @tempint   = CONVERT(int, SUBSTRING(@binvalue, @i, 1));
        SET @firstint  = FLOOR(@tempint / 16);
        SET @secondint = @tempint - (@firstint * 16);
        SET @charvalue = @charvalue + SUBSTRING(@hexstring, @firstint + 1, 1) + SUBSTRING(@hexstring, @secondint + 1, 1);
        SET @i += 1;
    END;

    SET @hexvalue = @charvalue;
END;
GO

IF OBJECT_ID(N'dbo.sp_help_revlogin') IS NOT NULL
    DROP PROCEDURE dbo.sp_help_revlogin;
GO
CREATE PROCEDURE dbo.sp_help_revlogin
    @login_name sysname = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @name                  sysname,
            @type                  varchar(1),
            @hasaccess             int,
            @denylogin             int,
            @is_disabled           int,
            @PWD_varbinary         varbinary(256),
            @PWD_string            varchar(514),
            @SID_varbinary         varbinary(85),
            @SID_string            varchar(514),
            @tmpstr                varchar(1024),
            @is_policy_checked     varchar(3),
            @is_expiration_checked varchar(3),
            @defaultdb             sysname,
            @defaultlanguage       sysname,
            @tmpstrRole            varchar(1024);

    DECLARE login_curs CURSOR LOCAL FAST_FORWARD FOR
        SELECT p.sid, p.name, p.type, p.is_disabled, p.default_database_name,
               l.hasaccess, l.denylogin, p.default_language_name
        FROM sys.server_principals AS p
        LEFT JOIN sys.syslogins AS l ON l.name = p.name
        WHERE p.type IN ('S', 'G', 'U')
          AND p.name <> 'sa'
          AND p.name NOT LIKE '##%'
          AND p.name NOT LIKE 'NT SERVICE\%'
          AND p.name NOT LIKE 'NT AUTHORITY\%'
          AND (@login_name IS NULL OR p.name = @login_name)
        ORDER BY p.name;

    OPEN login_curs;
    FETCH NEXT FROM login_curs INTO @SID_varbinary, @name, @type, @is_disabled, @defaultdb, @hasaccess, @denylogin, @defaultlanguage;

    IF (@@FETCH_STATUS = -1)
    BEGIN
        PRINT 'No login(s) found.';
        CLOSE login_curs;
        DEALLOCATE login_curs;
        RETURN -1;
    END;

    PRINT '/* sp_help_revlogin script';
    PRINT '** Generated ' + CONVERT(varchar(30), GETDATE(), 120) + ' on ' + @@SERVERNAME + ' */';

    WHILE (@@FETCH_STATUS <> -1)
    BEGIN
        IF (@@FETCH_STATUS <> -2)
        BEGIN
            PRINT '';
            PRINT '-- Login: ' + @name;
            PRINT 'IF NOT EXISTS (SELECT * FROM sys.server_principals WHERE name = N''' + REPLACE(@name, '''', '''''') + ''')';
            PRINT 'BEGIN';

            IF (@type IN ('G', 'U'))
            BEGIN
                SET @tmpstr = '    CREATE LOGIN ' + QUOTENAME(@name) + ' FROM WINDOWS WITH DEFAULT_DATABASE = ['
                            + @defaultdb + '], DEFAULT_LANGUAGE = [' + @defaultlanguage + ']';
            END
            ELSE
            BEGIN
                SET @PWD_varbinary = CAST(LOGINPROPERTY(@name, 'PasswordHash') AS varbinary(256));
                EXEC dbo.sp_hexadecimal @PWD_varbinary, @PWD_string OUT;
                EXEC dbo.sp_hexadecimal @SID_varbinary, @SID_string OUT;

                SELECT @is_policy_checked     = CASE is_policy_checked     WHEN 1 THEN 'ON' WHEN 0 THEN 'OFF' END,
                       @is_expiration_checked = CASE is_expiration_checked WHEN 1 THEN 'ON' WHEN 0 THEN 'OFF' END
                FROM sys.sql_logins
                WHERE name = @name;

                SET @tmpstr = '    CREATE LOGIN ' + QUOTENAME(@name) + ' WITH PASSWORD = ' + @PWD_string
                            + ' HASHED, SID = ' + @SID_string + ', DEFAULT_DATABASE = [' + @defaultdb
                            + '], DEFAULT_LANGUAGE = [' + @defaultlanguage + ']';

                IF @is_policy_checked     IS NOT NULL SET @tmpstr += ', CHECK_POLICY = '     + @is_policy_checked;
                IF @is_expiration_checked IS NOT NULL SET @tmpstr += ', CHECK_EXPIRATION = ' + @is_expiration_checked;
            END;

            IF (@denylogin = 1)
                SET @tmpstr += '; DENY CONNECT SQL TO ' + QUOTENAME(@name);
            ELSE IF (@hasaccess = 0)
                SET @tmpstr += '; REVOKE CONNECT SQL TO ' + QUOTENAME(@name);

            IF (@is_disabled = 1)
                SET @tmpstr += '; ALTER LOGIN ' + QUOTENAME(@name) + ' DISABLE';

            -- Server role membership (fixed and user-defined roles)
            SET @tmpstrRole = '';
            SELECT @tmpstrRole += CHAR(13) + CHAR(10) + '    ALTER SERVER ROLE ' + QUOTENAME(r.name) + ' ADD MEMBER ' + QUOTENAME(@name) + ';'
            FROM sys.server_role_members AS rm
            JOIN sys.server_principals AS r ON r.principal_id = rm.role_principal_id
            JOIN sys.server_principals AS m ON m.principal_id = rm.member_principal_id
            WHERE m.name = @name
              AND r.name <> 'public';

            PRINT @tmpstr + ';';
            IF @tmpstrRole <> '' PRINT @tmpstrRole;
            PRINT 'END';
        END;

        FETCH NEXT FROM login_curs INTO @SID_varbinary, @name, @type, @is_disabled, @defaultdb, @hasaccess, @denylogin, @defaultlanguage;
    END;

    CLOSE login_curs;
    DEALLOCATE login_curs;
    RETURN 0;
END;
GO
