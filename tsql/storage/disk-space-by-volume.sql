/*
Script  : disk-space-by-volume.sql
Purpose : Free and used space in GB for every volume that holds a database file,
          plus xp_fixeddrives for drives with no database files on them.
Usage   : Run as is.
Changes : Read-only.
Requires: SQL Server 2016 and later.
Notes   : sys.dm_os_volume_stats only returns volumes that hold at least one
          data or log file, so C: and backup drives often do not appear there.
          xp_fixeddrives covers all fixed drives (free space only).
          For total size of every drive use powershell/Get-DiskSpace.ps1.
*/

-- 1. Volumes holding database files
SELECT DISTINCT
    vs.volume_mount_point                                         AS drive,
    vs.logical_volume_name                                        AS volume_name,
    CAST(vs.total_bytes / 1073741824.0 AS decimal(18,1))          AS total_gb,
    CAST(vs.available_bytes / 1073741824.0 AS decimal(18,1))      AS free_gb,
    CAST((vs.total_bytes - vs.available_bytes) / 1073741824.0 AS decimal(18,1)) AS used_gb,
    CAST(vs.available_bytes * 100.0 / vs.total_bytes AS decimal(5,2))           AS free_pct
FROM sys.master_files AS mf
CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) AS vs
ORDER BY drive;

-- 2. All fixed drives, free space only
DECLARE @drives TABLE (drive char(1), free_mb int);
INSERT INTO @drives EXEC master.dbo.xp_fixeddrives;
SELECT drive, CAST(free_mb / 1024.0 AS decimal(18,1)) AS free_gb
FROM @drives
ORDER BY drive;
