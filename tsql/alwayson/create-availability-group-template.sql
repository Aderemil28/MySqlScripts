/*
Script  : create-availability-group-template.sql
Purpose : End-to-end template for a two-replica availability group with
          automatic seeding: endpoints, endpoint permissions, AlwaysOn_health
          XE session, the AG itself, a listener, and the secondary join.
Usage   : Must run in SQLCMD mode (SSMS: Query > SQLCMD Mode).
          Replace every value in the :setvar block. The database must be in
          FULL recovery with at least one full backup taken.
Changes : Creates endpoints, an availability group and a listener.
Requires: SQL Server 2016 and later, Windows Server Failover Cluster already built.
*/
:setvar Replica1        "SQLNODE01"
:setvar Replica2        "SQLNODE02"
:setvar Domain          "corp.example"
:setvar ServiceAccount  "CORP\svc_sqlengine"
:setvar AGName          "AG_App01"
:setvar DatabaseName    "AppDB"
:setvar ListenerName    "AG_App01_LSN"
:setvar ListenerIP      "10.0.0.50"
:setvar ListenerMask    "255.255.255.0"
:setvar ListenerPort    "1433"

/* ---------- 1. Endpoint, permissions and health session on replica 1 ---------- */
:Connect $(Replica1)
USE [master];
GO
IF NOT EXISTS (SELECT 1 FROM sys.database_mirroring_endpoints)
    CREATE ENDPOINT [Hadr_endpoint]
        AS TCP (LISTENER_PORT = 5022)
        FOR DATA_MIRRORING (ROLE = ALL, ENCRYPTION = REQUIRED ALGORITHM AES);
GO
IF (SELECT state FROM sys.endpoints WHERE name = N'Hadr_endpoint') <> 0
    ALTER ENDPOINT [Hadr_endpoint] STATE = STARTED;
GO
IF SUSER_ID(N'$(ServiceAccount)') IS NULL CREATE LOGIN [$(ServiceAccount)] FROM WINDOWS;
GRANT CONNECT ON ENDPOINT::[Hadr_endpoint] TO [$(ServiceAccount)];
GO
IF EXISTS (SELECT * FROM sys.server_event_sessions WHERE name = N'AlwaysOn_health')
    ALTER EVENT SESSION [AlwaysOn_health] ON SERVER WITH (STARTUP_STATE = ON);
IF NOT EXISTS (SELECT * FROM sys.dm_xe_sessions WHERE name = N'AlwaysOn_health')
    ALTER EVENT SESSION [AlwaysOn_health] ON SERVER STATE = START;
GO

/* ---------- 2. Same on replica 2 ---------- */
:Connect $(Replica2)
USE [master];
GO
IF NOT EXISTS (SELECT 1 FROM sys.database_mirroring_endpoints)
    CREATE ENDPOINT [Hadr_endpoint]
        AS TCP (LISTENER_PORT = 5022)
        FOR DATA_MIRRORING (ROLE = ALL, ENCRYPTION = REQUIRED ALGORITHM AES);
GO
IF (SELECT state FROM sys.endpoints WHERE name = N'Hadr_endpoint') <> 0
    ALTER ENDPOINT [Hadr_endpoint] STATE = STARTED;
GO
IF SUSER_ID(N'$(ServiceAccount)') IS NULL CREATE LOGIN [$(ServiceAccount)] FROM WINDOWS;
GRANT CONNECT ON ENDPOINT::[Hadr_endpoint] TO [$(ServiceAccount)];
GO
IF EXISTS (SELECT * FROM sys.server_event_sessions WHERE name = N'AlwaysOn_health')
    ALTER EVENT SESSION [AlwaysOn_health] ON SERVER WITH (STARTUP_STATE = ON);
IF NOT EXISTS (SELECT * FROM sys.dm_xe_sessions WHERE name = N'AlwaysOn_health')
    ALTER EVENT SESSION [AlwaysOn_health] ON SERVER STATE = START;
GO

/* ---------- 3. Create the AG on replica 1 ---------- */
:Connect $(Replica1)
USE [master];
GO
CREATE AVAILABILITY GROUP [$(AGName)]
WITH (AUTOMATED_BACKUP_PREFERENCE = SECONDARY,
      DB_FAILOVER = ON,
      DTC_SUPPORT = NONE,
      REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT = 0)
FOR DATABASE [$(DatabaseName)]
REPLICA ON
    N'$(Replica1)' WITH (ENDPOINT_URL = N'TCP://$(Replica1).$(Domain):5022',
        FAILOVER_MODE = AUTOMATIC, AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
        BACKUP_PRIORITY = 50, SEEDING_MODE = AUTOMATIC,
        SECONDARY_ROLE (ALLOW_CONNECTIONS = NO)),
    N'$(Replica2)' WITH (ENDPOINT_URL = N'TCP://$(Replica2).$(Domain):5022',
        FAILOVER_MODE = AUTOMATIC, AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
        BACKUP_PRIORITY = 50, SEEDING_MODE = AUTOMATIC,
        SECONDARY_ROLE (ALLOW_CONNECTIONS = NO));
GO

/* ---------- 4. Listener ---------- */
:Connect $(Replica1)
ALTER AVAILABILITY GROUP [$(AGName)]
ADD LISTENER N'$(ListenerName)' (WITH IP ((N'$(ListenerIP)', N'$(ListenerMask)')), PORT = $(ListenerPort));
GO

/* ---------- 5. Join replica 2 and allow automatic seeding ---------- */
:Connect $(Replica2)
ALTER AVAILABILITY GROUP [$(AGName)] JOIN;
GO
ALTER AVAILABILITY GROUP [$(AGName)] GRANT CREATE ANY DATABASE;
GO
