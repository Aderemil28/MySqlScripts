/*
Script  : file-io-latency.sql
Purpose : Average read and write latency per database file since the last
          restart, with I/O volume. Rough guide: under 10 ms is good, 10 to 20 ms
          is worth watching, over 20 ms on data files or over 5 ms on log
          files usually means storage is a bottleneck.
Usage   : Run as is. Numbers are cumulative since startup, so compare two runs
          a few minutes apart to see what is happening right now.
Changes : Read-only.
Requires: SQL Server 2016 and later.
*/
SELECT
    DB_NAME(vfs.database_id)                                                   AS database_name,
    mf.name                                                                    AS logical_name,
    mf.type_desc                                                               AS file_type,
    mf.physical_name,
    vfs.num_of_reads,
    vfs.num_of_writes,
    CAST(vfs.num_of_bytes_read    / 1048576.0 AS decimal(18,1))                AS mb_read,
    CAST(vfs.num_of_bytes_written / 1048576.0 AS decimal(18,1))                AS mb_written,
    CAST(vfs.io_stall_read_ms  * 1.0 / NULLIF(vfs.num_of_reads, 0)  AS decimal(10,2)) AS avg_read_latency_ms,
    CAST(vfs.io_stall_write_ms * 1.0 / NULLIF(vfs.num_of_writes, 0) AS decimal(10,2)) AS avg_write_latency_ms,
    vfs.io_stall_read_ms                                                       AS total_read_stall_ms,
    vfs.io_stall_write_ms                                                      AS total_write_stall_ms
FROM sys.dm_io_virtual_file_stats(NULL, NULL) AS vfs
JOIN sys.master_files AS mf
  ON mf.database_id = vfs.database_id
 AND mf.file_id     = vfs.file_id
ORDER BY (vfs.io_stall_read_ms + vfs.io_stall_write_ms) DESC;
