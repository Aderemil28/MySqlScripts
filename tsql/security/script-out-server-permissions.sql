/*
Script  : script-out-server-permissions.sql
Purpose : Generates GRANT and DENY statements for every server-level permission
          held by logins (VIEW SERVER STATE, ALTER ANY DATABASE, CONNECT on an
          endpoint, IMPERSONATE on a login, and so on). Run it before a
          migration, a rebuild or a security change, and keep the output: it
          puts the same server permissions back on any instance.
Usage   : Run as is, copy the generated_command column, review, run on the
          target. Logins must exist on the target first
          (script-out-logins-sp_help_revlogin.sql).
          Set @IncludeServiceAccounts = 1 to include NT SERVICE\ and
          NT AUTHORITY\ accounts.
Changes : Read-only. It only prints statements.
Requires: SQL Server 2016 and later.
Fixes vs the original notes:
          - only scripted state G; WITH GRANT OPTION (W) and DENY (D) were lost
          - every permission was scripted as server-wide, so CONNECT on an
            endpoint or IMPERSONATE on a login produced an invalid statement;
            the ON ENDPOINT:: and ON LOGIN:: target is now added
          - names are wrapped in QUOTENAME
          - the default CONNECT SQL that every login gets is left out
          A target that cannot be resolved prints as a [<placeholder>]; fill
          it in by hand.
*/
SET NOCOUNT ON;

DECLARE @IncludeServiceAccounts bit = 0;

SELECT  pr.name                       AS grantee,
        pr.type_desc                  AS grantee_type,
        perm.class_desc,
        perm.permission_name,
        perm.state_desc,
        CASE perm.state WHEN 'D' THEN N'DENY ' ELSE N'GRANT ' END
          + perm.permission_name
          + CASE perm.class
                 WHEN 105 THEN N' ON ENDPOINT::' + ISNULL(QUOTENAME(ep.name), N'[<endpoint>]')
                 WHEN 101 THEN N' ON LOGIN::'    + ISNULL(QUOTENAME(tgt.name), N'[<login>]')
                 WHEN 108 THEN N' ON AVAILABILITY GROUP::' + ISNULL(QUOTENAME(ag.name), N'[<availability group>]')
                 ELSE N'' END
          + N' TO ' + QUOTENAME(pr.name)
          + CASE perm.state WHEN 'W' THEN N' WITH GRANT OPTION' ELSE N'' END
          + N';'                      AS generated_command
FROM sys.server_permissions  AS perm
JOIN sys.server_principals   AS pr  ON pr.principal_id = perm.grantee_principal_id
LEFT JOIN sys.endpoints         AS ep  ON perm.class = 105 AND ep.endpoint_id   = perm.major_id
LEFT JOIN sys.server_principals AS tgt ON perm.class = 101 AND tgt.principal_id = perm.major_id
LEFT JOIN sys.availability_replicas AS ar ON perm.class = 108 AND ar.replica_metadata_id = perm.major_id
LEFT JOIN sys.availability_groups   AS ag ON ag.group_id = ar.group_id
WHERE perm.state IN ('G', 'W', 'D')
  AND pr.type NOT IN ('R')                              -- server roles: script role membership separately
  AND pr.name NOT LIKE N'##%'                           -- internal certificate logins
  AND NOT (perm.permission_name = N'CONNECT SQL' AND perm.class = 100 AND perm.state = 'G')
  AND (@IncludeServiceAccounts = 1
       OR (pr.name NOT LIKE N'NT SERVICE\%' AND pr.name NOT LIKE N'NT AUTHORITY\%'))
ORDER BY pr.name, perm.permission_name;
