/*
Script  : databases-topology-and-role.sql
Purpose : Every user database on the instance, whether it is standalone or in an
          availability group (and which one), and whether this replica is the
          primary or a secondary for it. Run it through a CMS or multi-server
          query window to inventory a whole estate in one go.
Usage   : Run as is. Set @PrimaryOnly = 1 to list only databases that are
          read-write here (standalone, or primary replica). That avoids counting
          an AG database twice when you query every node.
Changes : Read-only.
Requires: SQL Server 2016 and later.
Fixes vs the original notes:
          - the original always filtered to primary or standalone, so secondary
            databases were silently missing; that filter is now @PrimaryOnly
          - added synchronization state and health so a secondary that is not
            synchronizing shows up
*/
SET NOCOUNT ON;

DECLARE @PrimaryOnly bit = 0;

SELECT  @@SERVERNAME                                          AS server_name,
        d.name                                                AS database_name,
        CASE WHEN ag.name IS NOT NULL THEN N'AG member (' + ag.name + N')'
             ELSE N'Standalone' END                           AS topology,
        CASE rs.is_primary_replica WHEN 1 THEN N'Primary'
                                   WHEN 0 THEN N'Secondary'
                                   ELSE N'N/A' END            AS role,
        rs.synchronization_state_desc,
        rs.synchronization_health_desc,
        d.recovery_model_desc,
        d.state_desc,
        d.compatibility_level
FROM sys.databases AS d
LEFT JOIN sys.dm_hadr_database_replica_states AS rs
       ON rs.database_id = d.database_id AND rs.is_local = 1
LEFT JOIN sys.availability_groups AS ag
       ON ag.group_id = rs.group_id
WHERE d.database_id > 4
  AND (@PrimaryOnly = 0 OR rs.is_primary_replica = 1 OR rs.is_primary_replica IS NULL)
ORDER BY d.name;
