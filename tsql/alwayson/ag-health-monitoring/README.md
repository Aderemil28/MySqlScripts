# AG health monitoring

A small, self-contained history of availability group health, so you can answer
"when did this start?" after an incident instead of only seeing the current state.

Run the scripts in order on **every replica**, so collection carries on after a failover:

| Step | Script | What it creates |
|---|---|---|
| 1 | [01-create-table-and-procedures.sql](01-create-table-and-procedures.sql) | `DBAUtil` database, `dbo.AGHealthStatus` table, collector and purge procedures |
| 2 | [02-create-agent-jobs.sql](02-create-agent-jobs.sql) | `DBA - AG Health Collect` (every 15 minutes) and `DBA - AG Health Purge` (daily, 30-day retention) |
| 3 | [03-daily-email-report.sql](03-daily-email-report.sql) | Optional `DBA - AG Health Daily Email` at 08:00 (needs Database Mail and SQL Server 2017+) |

Useful queries once it is running:

```sql
-- Anything unhealthy in the last day
SELECT * FROM DBAUtil.dbo.AGHealthStatus
WHERE LoggedAt >= DATEADD(DAY, -1, GETDATE()) AND (SyncHealth <> 'HEALTHY' OR IsSuspended = 1)
ORDER BY LoggedAt;

-- Lag trend for one database
SELECT LoggedAt, ReplicaServerName, SecondaryLagSeconds, LogSendQueueKB, RedoQueueKB
FROM DBAUtil.dbo.AGHealthStatus
WHERE DatabaseName = N'YourDatabase' AND ReplicaRole = 'SECONDARY'
ORDER BY LoggedAt;
```
