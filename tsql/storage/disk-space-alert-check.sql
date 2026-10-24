/*
Script  : disk-space-alert-check.sql
Purpose : Returns only the volumes (holding database files) that are below a
          free-space threshold. Built to be dropped into an Agent job step or a
          CMS multi-server query so you only see what needs attention.
Usage   : Set @MinFreePct. No rows means every volume is above the threshold.
Changes : Read-only.
Requires: SQL Server 2016 and later.
*/
DECLARE @MinFreePct decimal(5,2) = 15.0;

SELECT DISTINCT
    @@SERVERNAME                                                 AS server_name,
    vs.volume_mount_point                                        AS drive,
    CAST(vs.total_bytes / 1073741824.0 AS decimal(18,1))         AS total_gb,
    CAST(vs.available_bytes / 1073741824.0 AS decimal(18,1))     AS free_gb,
    CAST(vs.available_bytes * 100.0 / vs.total_bytes AS decimal(5,2)) AS free_pct
FROM sys.master_files AS mf
CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) AS vs
WHERE vs.available_bytes * 100.0 / vs.total_bytes < @MinFreePct
ORDER BY free_pct;
