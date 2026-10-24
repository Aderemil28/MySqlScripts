/*
Script  : memory-usage.sql
Purpose : Memory picture for the server and the SQL Server process:
            1. OS physical memory and its state
            2. SQL Server process memory and low-memory flags
            3. Committed vs target memory, and max server memory setting
            4. Top memory clerks
            5. Buffer pool use per database
Usage   : Run as is.
Changes : Read-only.
Requires: SQL Server 2016 and later.
*/

-- 1. OS memory
SELECT total_physical_memory_kb / 1024     AS total_physical_mb,
       available_physical_memory_kb / 1024 AS available_physical_mb,
       system_memory_state_desc
FROM sys.dm_os_sys_memory;

-- 2. SQL Server process
SELECT physical_memory_in_use_kb / 1024 AS sql_physical_memory_used_mb,
       locked_page_allocations_kb / 1024 AS locked_pages_mb,
       memory_utilization_percentage,
       process_physical_memory_low,
       process_virtual_memory_low
FROM sys.dm_os_process_memory;

-- 3. Committed vs target, and the configured cap
SELECT committed_kb / 1024        AS sql_committed_mb,
       committed_target_kb / 1024 AS sql_target_mb,
       (SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = N'max server memory (MB)') AS max_server_memory_mb
FROM sys.dm_os_sys_info;

-- 4. Top memory clerks
SELECT TOP (10) [type], SUM(pages_kb) / 1024 AS size_mb
FROM sys.dm_os_memory_clerks
GROUP BY [type]
ORDER BY size_mb DESC;

-- 5. Buffer pool by database (can take a few seconds on large memory servers)
SELECT CASE database_id WHEN 32767 THEN N'ResourceDb' ELSE DB_NAME(database_id) END AS database_name,
       COUNT_BIG(*) * 8 / 1024 AS buffer_pool_mb
FROM sys.dm_os_buffer_descriptors
GROUP BY database_id
ORDER BY buffer_pool_mb DESC;
