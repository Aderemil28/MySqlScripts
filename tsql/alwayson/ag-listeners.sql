/*
Script  : ag-listeners.sql
Purpose : Availability group listeners with DNS name, port, IPs and state.
Usage   : Run on any replica.
Changes : Read-only.
Requires: SQL Server 2016 and later.
*/
SELECT
    ag.name                                      AS ag_name,
    agl.dns_name                                 AS listener_dns_name,
    agl.port,
    lip.ip_address,
    lip.ip_subnet_mask,
    lip.state_desc                               AS ip_state,
    agl.ip_configuration_string_from_cluster
FROM sys.availability_groups AS ag
JOIN sys.availability_group_listeners AS agl ON agl.group_id = ag.group_id
LEFT JOIN sys.availability_group_listener_ip_addresses AS lip ON lip.listener_id = agl.listener_id
ORDER BY ag.name, lip.ip_address;
