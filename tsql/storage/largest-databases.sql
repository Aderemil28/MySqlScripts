/*
Script  : largest-databases.sql
Purpose : Databases ranked by allocated size, with data and log split out and
          the total in MB, GB and TB. Quick answer to "what are the biggest
          databases on this server" for capacity planning or a refresh request.
Usage   : Run as is. Set @IncludeSystem = 1 to include master, model, msdb and
          tempdb. For used versus free space inside each file, use
          database-file-sizes-and-free-space.sql.
Changes : Read-only.
Requires: SQL Server 2016 and later.
Fixes vs the original notes: a database with no file of one type (for example
          a missing log row while a database is offline) returned NULL instead
          of 0; sizes are now wrapped in ISNULL. Added online/offline state so
          sizes for offline databases are not mistaken for live ones.
*/
SET NOCOUNT ON;

DECLARE @IncludeSystem bit = 0;

SELECT  d.name                                                                          AS database_name,
        d.state_desc                                                                    AS state,
        d.recovery_model_desc                                                           AS recovery_model,
        CAST(ISNULL(SUM(CASE WHEN mf.type = 0 THEN mf.size END), 0) * 8.0 / 1024 AS decimal(18,2))      AS data_file_mb,
        CAST(ISNULL(SUM(CASE WHEN mf.type = 1 THEN mf.size END), 0) * 8.0 / 1024 AS decimal(18,2))      AS log_file_mb,
        CAST(SUM(mf.size) * 8.0 / 1024               AS decimal(18,2))                  AS total_allocated_mb,
        CAST(SUM(mf.size) * 8.0 / 1024 / 1024        AS decimal(18,2))                  AS total_allocated_gb,
        CAST(SUM(mf.size) * 8.0 / 1024 / 1024 / 1024 AS decimal(18,4))                  AS total_allocated_tb
FROM sys.master_files AS mf
JOIN sys.databases    AS d ON d.database_id = mf.database_id
WHERE @IncludeSystem = 1 OR d.database_id > 4
GROUP BY d.name, d.state_desc, d.recovery_model_desc
ORDER BY total_allocated_mb DESC;
