/*
Script  : encryption-tde-keys-and-certificates.sql
Purpose : Encryption inventory for the instance:
            1. TDE status for every database (encryption state, algorithm, certificate)
            2. Certificates in master with expiry dates (TDE and backup encryption certs live here)
            3. Symmetric and asymmetric keys in the current database
            4. Columns that may hold encrypted data (varbinary/binary/image) in the current database
Usage   : Run as is. Sections 3 and 4 run against the current database.
Changes : Read-only.
Requires: SQL Server 2016 and later.
*/

-- 1. TDE status (no row = database not encrypted)
SELECT
    d.name AS database_name,
    d.is_encrypted,
    k.encryption_state,                       -- 3 = encrypted, 2 = encryption in progress
    CASE k.encryption_state WHEN 0 THEN 'No key'
                            WHEN 1 THEN 'Unencrypted'
                            WHEN 2 THEN 'Encryption in progress'
                            WHEN 3 THEN 'Encrypted'
                            WHEN 4 THEN 'Key change in progress'
                            WHEN 5 THEN 'Decryption in progress'
                            WHEN 6 THEN 'Protection change in progress' END AS encryption_state_desc,
    k.percent_complete,
    k.key_algorithm,
    k.key_length,
    c.name        AS certificate_name,
    c.expiry_date AS certificate_expiry
FROM sys.databases AS d
LEFT JOIN sys.dm_database_encryption_keys AS k ON k.database_id = d.database_id
LEFT JOIN master.sys.certificates AS c ON c.thumbprint = k.encryptor_thumbprint
ORDER BY d.name;

-- 2. Certificates in master
SELECT name, subject, start_date, expiry_date, pvt_key_encryption_type_desc, thumbprint
FROM master.sys.certificates
WHERE name NOT LIKE N'##%'
ORDER BY expiry_date;

-- 3. Keys in the current database
SELECT 'Symmetric' AS key_kind, name, algorithm_desc, key_length, create_date, modify_date
FROM sys.symmetric_keys
UNION ALL
SELECT 'Asymmetric', name, algorithm_desc, key_length, NULL, NULL
FROM sys.asymmetric_keys;

-- 4. Binary columns in the current database
SELECT s.name AS [schema], t.name AS [table], c.name AS [column], ty.name AS data_type
FROM sys.columns AS c
JOIN sys.types   AS ty ON ty.user_type_id = c.user_type_id
JOIN sys.tables  AS t  ON t.object_id = c.object_id
JOIN sys.schemas AS s  ON s.schema_id = t.schema_id
WHERE ty.name IN ('binary', 'varbinary', 'image')
ORDER BY s.name, t.name, c.name;
