/*
Script  : python-r-external-scripts-check.sql
Purpose : Answers "is SQL Server using Python or R?" for a vulnerability finding.
          Checks the external scripts setting, the Launchpad service, and
          whether any external script has run since startup.
Usage   : Run as is. If external scripts are disabled and there is no Launchpad
          service, SQL Server is not the process using Python on that host.
          Use powershell/Find-PythonRuntime.ps1 to find what is.
Changes : Read-only.
Requires: SQL Server 2016 and later.
*/
SELECT name, value_in_use
FROM sys.configurations
WHERE name = N'external scripts enabled';

SELECT servicename, status_desc, startup_type_desc
FROM sys.dm_server_services
WHERE servicename LIKE N'%Launchpad%';

-- Executions since startup (no rows or zeros = never used)
SELECT language, counter_name, counter_value
FROM sys.dm_external_script_execution_stats;
