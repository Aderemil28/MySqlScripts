/*
Script  : connection-strings-by-database.sql
Purpose : Suggested connection strings for every user database. Databases in an
          availability group get the listener name and port plus
          MultiSubnetFailover=True; others get the instance name. Handy when an
          app team asks "what should our connection string be?"
Usage   : Run on the primary replica.
Changes : Read-only.
Requires: SQL Server 2016 and later.
*/
SELECT
    @@SERVERNAME                       AS server_name,
    d.name                             AS database_name,
    ag.name                            AS ag_name,
    ars.role_desc                      AS current_role,
    agl.dns_name                       AS ag_listener,
    agl.port                           AS listener_port,
    N'Server=' + COALESCE(agl.dns_name + N',' + CAST(agl.port AS nvarchar(10)), @@SERVERNAME)
        + N';Database=' + d.name
        + N';Integrated Security=SSPI;'
        + CASE WHEN agl.dns_name IS NOT NULL THEN N'MultiSubnetFailover=True;' ELSE N'' END AS connection_string
FROM sys.databases AS d
LEFT JOIN sys.dm_hadr_availability_replica_states AS ars ON ars.replica_id = d.replica_id
LEFT JOIN sys.availability_groups AS ag ON ag.group_id = ars.group_id
LEFT JOIN sys.availability_group_listeners AS agl ON agl.group_id = ag.group_id
WHERE d.database_id > 4
  AND d.state_desc = N'ONLINE'
ORDER BY ag.name, d.name;
