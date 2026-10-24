/*
Script  : database-permissions-report.sql
Purpose : Who can do what in the current database. Lists permissions granted
          directly to users, permissions inherited through database roles, and
          permissions granted to public, down to column level.
Usage   : USE the database and run. Filter the output on UserName if needed.
Changes : Read-only.
Requires: SQL Server 2016 and later.
Source  : Based on a widely shared Stack Overflow answer. Fixed the ORDER BY,
          which referenced table aliases and fails on a UNION, and added
          Windows groups.
*/
SELECT
    UserName         = CASE princ.type WHEN 'S' THEN princ.name ELSE COALESCE(ulogin.name, princ.name) END,
    UserType         = princ.type_desc,
    DatabaseUserName = princ.name,
    [Role]           = CAST(NULL AS sysname),
    PermissionType   = perm.permission_name,
    PermissionState  = perm.state_desc,
    ObjectType       = obj.type_desc,
    ObjectName       = OBJECT_NAME(perm.major_id),
    ColumnName       = col.name
FROM sys.database_principals AS princ
LEFT JOIN sys.server_principals   AS ulogin ON ulogin.sid = princ.sid
LEFT JOIN sys.database_permissions AS perm  ON perm.grantee_principal_id = princ.principal_id
LEFT JOIN sys.columns             AS col    ON col.object_id = perm.major_id AND col.column_id = perm.minor_id
LEFT JOIN sys.objects             AS obj    ON obj.object_id = perm.major_id
WHERE princ.type IN ('S', 'U', 'G')

UNION

SELECT
    CASE memberprinc.type WHEN 'S' THEN memberprinc.name ELSE COALESCE(ulogin.name, memberprinc.name) END,
    memberprinc.type_desc,
    memberprinc.name,
    roleprinc.name,
    perm.permission_name,
    perm.state_desc,
    obj.type_desc,
    OBJECT_NAME(perm.major_id),
    col.name
FROM sys.database_role_members AS members
JOIN sys.database_principals   AS roleprinc   ON roleprinc.principal_id   = members.role_principal_id
JOIN sys.database_principals   AS memberprinc ON memberprinc.principal_id = members.member_principal_id
LEFT JOIN sys.server_principals    AS ulogin ON ulogin.sid = memberprinc.sid
LEFT JOIN sys.database_permissions AS perm   ON perm.grantee_principal_id = roleprinc.principal_id
LEFT JOIN sys.columns              AS col    ON col.object_id = perm.major_id AND col.column_id = perm.minor_id
LEFT JOIN sys.objects              AS obj    ON obj.object_id = perm.major_id

UNION

SELECT
    '{All Users}',
    '{All Users}',
    '{All Users}',
    roleprinc.name,
    perm.permission_name,
    perm.state_desc,
    obj.type_desc,
    OBJECT_NAME(perm.major_id),
    col.name
FROM sys.database_principals  AS roleprinc
JOIN sys.database_permissions AS perm ON perm.grantee_principal_id = roleprinc.principal_id
JOIN sys.objects              AS obj  ON obj.object_id = perm.major_id
LEFT JOIN sys.columns         AS col  ON col.object_id = perm.major_id AND col.column_id = perm.minor_id
WHERE roleprinc.type = 'R'
  AND roleprinc.name = 'public'
  AND obj.is_ms_shipped = 0

ORDER BY UserName, ObjectName, ColumnName, PermissionType, PermissionState, ObjectType;
