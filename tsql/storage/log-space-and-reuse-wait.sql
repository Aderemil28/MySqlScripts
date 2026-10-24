/*
Script  : log-space-and-reuse-wait.sql
Purpose : Transaction log size and % used for every database, and the reason the
          log cannot be truncated (log_reuse_wait_desc). This is the first thing
          to check when a log file keeps growing or a log drive fills up.
            LOG_BACKUP          : no log backup running or log backups failing
            ACTIVE_TRANSACTION  : a long open transaction (see blocking-chain.sql)
            AVAILABILITY_REPLICA: a secondary is behind (see ag-replica-health.sql)
            REPLICATION / CDC   : log reader or CDC capture is behind
Usage   : Run as is.
Changes : Read-only.
Requires: SQL Server 2016 and later.
*/
DECLARE @logspace TABLE (database_name sysname, log_size_mb decimal(18,2), log_used_pct decimal(5,2), status int);
INSERT INTO @logspace EXEC (N'DBCC SQLPERF(LOGSPACE) WITH NO_INFOMSGS');

SELECT
    d.name                    AS database_name,
    d.recovery_model_desc,
    d.log_reuse_wait_desc,
    l.log_size_mb,
    l.log_used_pct,
    CAST(l.log_size_mb * (100 - l.log_used_pct) / 100 AS decimal(18,2)) AS log_free_mb
FROM sys.databases AS d
JOIN @logspace AS l ON l.database_name = d.name
ORDER BY l.log_size_mb DESC;

-- Oldest open transaction in the current database
-- DBCC OPENTRAN WITH TABLERESULTS;
