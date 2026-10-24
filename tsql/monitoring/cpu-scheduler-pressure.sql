/*
Script  : cpu-scheduler-pressure.sql
Purpose : Quick CPU pressure check. Tasks waiting in the runnable queue mean
          they are ready to run but waiting for CPU. A sustained
          runnable_tasks_count above zero on most schedulers points to CPU
          pressure. Section 2 shows signal wait %, the same story over time.
Usage   : Run a few times during the slow period.
Changes : Read-only.
Requires: SQL Server 2016 and later.
*/

-- 1. Right now, per scheduler
SELECT
    parent_node_id,
    scheduler_id,
    status,
    current_tasks_count,
    runnable_tasks_count,
    work_queue_count,
    pending_disk_io_count
FROM sys.dm_os_schedulers
WHERE status = N'VISIBLE ONLINE'
ORDER BY runnable_tasks_count DESC, scheduler_id;

-- 2. Since last restart: share of wait time spent waiting for CPU (above ~20% is worth a look)
SELECT
    CAST(100.0 * SUM(signal_wait_time_ms) / NULLIF(SUM(wait_time_ms), 0) AS decimal(5,2)) AS signal_wait_pct,
    CAST(100.0 * SUM(wait_time_ms - signal_wait_time_ms) / NULLIF(SUM(wait_time_ms), 0) AS decimal(5,2)) AS resource_wait_pct
FROM sys.dm_os_wait_stats;
