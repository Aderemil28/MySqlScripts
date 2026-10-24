/*
Script  : 01-create-table-and-procedures.sql  (AG health monitoring, step 1 of 3)
Purpose : Creates a DBAUtil database (if missing), the dbo.AGHealthStatus table,
          the collector procedure dbo.usp_CollectAGHealth and the retention
          procedure dbo.usp_PurgeAGHealth.
Usage   : Run on every replica so collection keeps working after a failover.
          Then run 02-create-agent-jobs.sql and, optionally, 03-daily-email-report.sql.
Changes : Creates a database, a table and two procedures.
Requires: SQL Server 2016 SP1 and later (CREATE OR ALTER).
Fixes vs the original notes:
          - LSN columns are numeric(25,0); bigint overflows on long-lived databases
          - listener join is LEFT, so AGs without a listener are still captured
          - column names match what they hold (sync health vs sync state)
          - retention procedure is created in DBAUtil, not msdb
*/
IF DB_ID(N'DBAUtil') IS NULL
    CREATE DATABASE DBAUtil;
GO
USE DBAUtil;
GO

IF OBJECT_ID(N'dbo.AGHealthStatus', N'U') IS NULL
CREATE TABLE dbo.AGHealthStatus
(
    ID                    int IDENTITY(1,1) CONSTRAINT PK_AGHealthStatus PRIMARY KEY,
    CollectedOn           sysname       NOT NULL DEFAULT (@@SERVERNAME),
    AGName                sysname       NOT NULL,
    ReplicaServerName     nvarchar(256) NOT NULL,
    ReplicaRole           nvarchar(60)  NULL,
    DatabaseName          sysname       NULL,
    ListenerName          nvarchar(63)  NULL,
    SyncState             nvarchar(60)  NULL,
    SyncHealth            nvarchar(60)  NULL,
    IsSuspended           bit           NULL,
    LogSendQueueKB        bigint        NULL,
    RedoQueueKB           bigint        NULL,
    SecondaryLagSeconds   bigint        NULL,
    LastHardenedLSN       numeric(25,0) NULL,
    LastCommitLSN         numeric(25,0) NULL,
    LastCommitTime        datetime      NULL,
    BackupPriority        int           NULL,
    LoggedAt              datetime      NOT NULL DEFAULT (GETDATE())
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_AGHealthStatus_LoggedAt')
    CREATE INDEX IX_AGHealthStatus_LoggedAt ON dbo.AGHealthStatus (LoggedAt);
GO

CREATE OR ALTER PROCEDURE dbo.usp_CollectAGHealth
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO dbo.AGHealthStatus
        (AGName, ReplicaServerName, ReplicaRole, DatabaseName, ListenerName,
         SyncState, SyncHealth, IsSuspended, LogSendQueueKB, RedoQueueKB,
         SecondaryLagSeconds, LastHardenedLSN, LastCommitLSN, LastCommitTime, BackupPriority)
    SELECT
        ag.name,
        ar.replica_server_name,
        ars.role_desc,
        DB_NAME(drs.database_id),
        agl.dns_name,
        drs.synchronization_state_desc,
        drs.synchronization_health_desc,
        drs.is_suspended,
        drs.log_send_queue_size,
        drs.redo_queue_size,
        drs.secondary_lag_seconds,
        drs.last_hardened_lsn,
        drs.last_commit_lsn,
        drs.last_commit_time,
        ar.backup_priority
    FROM sys.availability_groups AS ag
    JOIN sys.availability_replicas AS ar ON ar.group_id = ag.group_id
    JOIN sys.dm_hadr_availability_replica_states AS ars ON ars.replica_id = ar.replica_id
    LEFT JOIN sys.dm_hadr_database_replica_states AS drs ON drs.replica_id = ar.replica_id
    LEFT JOIN sys.availability_group_listeners AS agl ON agl.group_id = ag.group_id;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_PurgeAGHealth
    @RetentionDays int = 30
AS
BEGIN
    SET NOCOUNT ON;

    -- Delete in batches so a large purge does not bloat the log or block the collector
    DECLARE @rows int = 1;
    WHILE @rows > 0
    BEGIN
        DELETE TOP (5000) FROM dbo.AGHealthStatus
        WHERE LoggedAt < DATEADD(DAY, -@RetentionDays, GETDATE());
        SET @rows = @@ROWCOUNT;
    END;
END;
GO

-- Quick test
EXEC dbo.usp_CollectAGHealth;
SELECT TOP (50) * FROM dbo.AGHealthStatus ORDER BY ID DESC;
