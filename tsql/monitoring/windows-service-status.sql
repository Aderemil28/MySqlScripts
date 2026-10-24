/*
Script  : windows-service-status.sql
Purpose : Check Windows services from inside SQL Server.
            1. SQL Server's own services (engine, Agent, full-text, Launchpad):
               status, account, startup type, IFI
            2. Any other Windows service by its service key name (for example a
               logging or monitoring agent), using xp_servicecontrol
Usage   : Section 2 needs the service KEY name (sc query / Get-Service Name
          column), not the display name. Requires sysadmin.
          For many servers at once, run it from a CMS server group or use
          powershell/Test-ServiceStatus.ps1.
Changes : Read-only.
Requires: SQL Server 2016 and later. xp_servicecontrol is undocumented but
          present in all current versions.
*/

-- 1. SQL Server services on this host
SELECT servicename, status_desc, startup_type_desc, service_account,
       instant_file_initialization_enabled, last_startup_time
FROM sys.dm_server_services;

-- 2. Any Windows service
DECLARE @ServiceName nvarchar(128) = N'W32Time';   -- service key name
DECLARE @state TABLE (current_state nvarchar(100));

INSERT INTO @state EXEC master.dbo.xp_servicecontrol N'QueryState', @ServiceName;

SELECT @@SERVERNAME AS server_name,
       @ServiceName AS service_name,
       current_state,
       CASE WHEN current_state LIKE N'Running%' THEN 'OK' ELSE 'CHECK' END AS result
FROM @state;
