/*
Script  : connections-auth-and-encryption.sql
Purpose : Connection-level detail for troubleshooting logins, Kerberos vs NTLM,
          TLS encryption, and "who is connecting from where with what app".
            1. All user connections with auth scheme, encryption and client IP
            2. Summary by login, host and auth scheme
            3. Unencrypted connections only (useful before forcing encryption)
            4. Is this session using Kerberos?
Usage   : Run the section you need.
Changes : Read-only.
Requires: SQL Server 2016 and later.
*/

-- 1. All user connections
SELECT
    c.session_id,
    s.login_name,
    s.original_login_name,
    s.host_name,
    c.client_net_address,
    c.local_tcp_port,
    c.net_transport,
    c.protocol_type,
    c.encrypt_option,
    c.auth_scheme,                       -- KERBEROS, NTLM or SQL
    s.program_name,
    s.client_interface_name,
    DB_NAME(s.database_id) AS database_name,
    s.status,
    s.login_time,
    c.connect_time,
    s.last_request_end_time
FROM sys.dm_exec_connections AS c
JOIN sys.dm_exec_sessions    AS s ON s.session_id = c.session_id
WHERE s.is_user_process = 1
ORDER BY s.login_time DESC;

-- 2. Summary by login, host and auth scheme
SELECT
    s.login_name,
    s.host_name,
    s.program_name,
    c.auth_scheme,
    c.encrypt_option,
    COUNT(*) AS connections
FROM sys.dm_exec_connections AS c
JOIN sys.dm_exec_sessions    AS s ON s.session_id = c.session_id
WHERE s.is_user_process = 1
GROUP BY s.login_name, s.host_name, s.program_name, c.auth_scheme, c.encrypt_option
ORDER BY connections DESC;

-- 3. Unencrypted connections
SELECT s.login_name, s.host_name, s.program_name, c.client_net_address, c.auth_scheme, c.connect_time
FROM sys.dm_exec_connections AS c
JOIN sys.dm_exec_sessions    AS s ON s.session_id = c.session_id
WHERE c.encrypt_option = 'FALSE'
  AND s.is_user_process = 1
ORDER BY c.connect_time DESC;

-- 4. Your own session
SELECT session_id, net_transport, auth_scheme, encrypt_option, client_net_address
FROM sys.dm_exec_connections
WHERE session_id = @@SPID;
