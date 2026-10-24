/*
Script  : clr-assemblies-and-trustworthy.sql
Purpose : CLR security review, often asked for after a vulnerability scan:
            1. Is CLR enabled, and is clr strict security on (2017+)?
            2. Databases with TRUSTWORTHY ON and who owns them
            3. User CLR assemblies in the current database and their permission set
            4. Trusted assemblies list (SQL Server 2017+ only)
Usage   : Run sections 1 to 3 on any version. Section 4 errors on 2016 because
          sys.trusted_assemblies was added in 2017, so it is commented out.
Changes : Read-only.
Requires: SQL Server 2016 and later.
*/

-- 1. CLR configuration
SELECT name, value, value_in_use
FROM sys.configurations
WHERE name IN (N'clr enabled', N'clr strict security');

-- 2. TRUSTWORTHY databases (msdb is TRUSTWORTHY by design)
SELECT d.name, d.is_trustworthy_on, SUSER_SNAME(d.owner_sid) AS owner
FROM sys.databases AS d
WHERE d.is_trustworthy_on = 1;

-- 3. User assemblies in the current database
SELECT a.name, a.permission_set_desc, a.clr_name, a.create_date, a.modify_date
FROM sys.assemblies AS a
WHERE a.is_user_defined = 1;

-- 4. SQL Server 2017+ only
-- SELECT hash, description, create_date, created_by FROM sys.trusted_assemblies;
