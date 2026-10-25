/*
Script  : ag-health-timeouts.sql
Purpose : Shows the settings that control how quickly an availability group
          decides the primary is unhealthy and fails over, and prints the
          commands to change them.
            HEALTH_CHECK_TIMEOUT   : how long the cluster waits for sp_server_diagnostics (default 30000 ms)
            FAILURE_CONDITION_LEVEL: which conditions trigger failover (1 to 5, default 3)
            LeaseTimeout           : cluster resource property (default 20000 ms), set in Failover Cluster Manager or PowerShell
Usage   : Set @AGName and the new values, run to review. Raising the timeouts can
          stop false failovers on busy or briefly unresponsive servers, at the cost
          of slower failover for a real outage. Change on the primary.
Changes : Read-only. The ALTER commands are printed, not executed.
Requires: SQL Server 2016 and later.
*/
DECLARE @AGName                sysname = N'YourAGName';
DECLARE @NewHealthCheckTimeout int     = 60000;   -- ms
DECLARE @NewFailureCondition   int     = 3;

SELECT
    ag.name,
    ag.health_check_timeout,
    ag.failure_condition_level,
    ag.automated_backup_preference_desc,
    ag.db_failover
FROM sys.availability_groups AS ag;

PRINT N'ALTER AVAILABILITY GROUP ' + QUOTENAME(@AGName) + N' SET (HEALTH_CHECK_TIMEOUT = '
    + CAST(@NewHealthCheckTimeout AS nvarchar(10)) + N');';
PRINT N'ALTER AVAILABILITY GROUP ' + QUOTENAME(@AGName) + N' SET (FAILURE_CONDITION_LEVEL = '
    + CAST(@NewFailureCondition AS nvarchar(10)) + N');';
PRINT N'-- LeaseTimeout (PowerShell, on a cluster node):';
PRINT N'--   Get-ClusterResource -Name ''' + @AGName + N''' | Get-ClusterParameter LeaseTimeout';
PRINT N'--   Get-ClusterResource -Name ''' + @AGName + N''' | Set-ClusterParameter LeaseTimeout 40000';
