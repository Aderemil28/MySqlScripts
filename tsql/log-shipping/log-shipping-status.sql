/*
Script  : log-shipping-status.sql
Purpose : Last log backup on the primary, and last copied and restored log on the
          secondary, with minutes since each. Answers "is log shipping behind?"
Usage   : Run section 1 on the primary instance and section 2 on the secondary.
          Section 3 is Microsoft's built-in summary and works on either side
          (or the monitor server).
Changes : Read-only.
Requires: SQL Server 2016 and later.
Fixes vs the original notes: missing comma between last_restored_date and
          last_restored_file, and an uncommented note line that broke the batch.
*/

-- 1. On the PRIMARY
SELECT
    primary_server,
    primary_database,
    last_backup_date,
    DATEDIFF(MINUTE, last_backup_date, GETDATE()) AS minutes_since_backup,
    backup_threshold                              AS alert_threshold_min,
    last_backup_file
FROM msdb.dbo.log_shipping_monitor_primary;

-- 2. On the SECONDARY
SELECT
    secondary_server,
    secondary_database,
    primary_server,
    last_copied_date,
    DATEDIFF(MINUTE, last_copied_date, GETDATE())   AS minutes_since_copy,
    last_copied_file,
    last_restored_date,
    DATEDIFF(MINUTE, last_restored_date, GETDATE()) AS minutes_since_restore,
    last_restored_file,
    restore_threshold                               AS alert_threshold_min
FROM msdb.dbo.log_shipping_monitor_secondary;

-- 3. Built-in status report (status 1 = alert)
EXEC master.sys.sp_help_log_shipping_monitor;
