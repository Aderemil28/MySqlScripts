/*
Script  : cpu-utilization-history.sql
Purpose : CPU use for roughly the last 4 hours in one-minute samples, split into
          SQL Server process, other processes and idle. Answers "was it SQL
          Server or something else on the box?"
Usage   : Change TOP (240) for a shorter or longer window (the ring buffer
          keeps about 256 minutes).
Changes : Read-only.
Requires: SQL Server 2016 and later.
Source  : Glenn Berry's diagnostic queries (CPU utilization history).
*/
DECLARE @ts_now bigint = (SELECT ms_ticks FROM sys.dm_os_sys_info);

SELECT TOP (240)
    DATEADD(MILLISECOND, -1 * (@ts_now - y.[timestamp]), GETDATE()) AS event_time,
    y.SQLProcessUtilization                                        AS sql_server_cpu_pct,
    100 - y.SystemIdle - y.SQLProcessUtilization                   AS other_process_cpu_pct,
    y.SystemIdle                                                   AS system_idle_pct
FROM
(
    SELECT
        x.record.value('(./Record/@id)[1]', 'int')                                                   AS record_id,
        x.record.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]', 'int')         AS SystemIdle,
        x.record.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]', 'int') AS SQLProcessUtilization,
        x.[timestamp]
    FROM
    (
        SELECT [timestamp], CONVERT(xml, record) AS record
        FROM sys.dm_os_ring_buffers
        WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR'
          AND record LIKE N'%<SystemHealth>%'
    ) AS x
) AS y
ORDER BY y.record_id DESC
OPTION (RECOMPILE);
