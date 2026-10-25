# SQL Server DBA Scripts

My personal toolkit of T-SQL, PowerShell and Robocopy scripts for running SQL
Server in production: backups and restores, Always On availability groups,
security and logins, monitoring, storage and day-to-day troubleshooting.

These are scripts I have written, collected and refined over the years. Every
one has a header explaining what it does, how to run it, and whether it changes
anything.

## How the scripts are written

* **Read-only by default.** Anything that changes something (kills sessions,
  drops users, grows files, alters tables) has an `@Execute` (T-SQL) or
  `-DryRun`/`-Upgrade` (PowerShell) switch and only prints what it would do
  until you turn it on.
* **No environment details.** Server names, paths and accounts are placeholders
  such as `YourDatabaseName`, `X:\SQLBackups\` or `CORP\svc_sqlengine`. Change
  them before running.
* **Standard header.** Every T-SQL file starts with Script, Purpose, Usage,
  Changes and Requires. Every PowerShell file has comment-based help, so
  `Get-Help .\Script.ps1 -Full` works.
* **Credit where it is due.** Scripts based on someone else's work say so in a
  `Source` line. Large community tools (Ola Hallengren, sp_WhoIsActive, First
  Responder Kit) are linked, not copied. See
  [cheatsheets/third-party-tools.md](cheatsheets/third-party-tools.md).

Always test in a non-production environment first.

## Repository layout

```
tsql/
  agent-jobs/       SQL Agent job failures, schedules, step search, Ola schedules
  alwayson/         AG health, lag, failover readiness, listeners, seeding, AG build template
    ag-health-monitoring/   table + collector + jobs + daily email for AG health history
  backup-restore/   backups, restore commands, history, LSN chain, progress
  log-shipping/     log shipping status
  maintenance/      add primary keys, clear sessions, schema object counts
  monitoring/       blocking, CPU, memory, I/O latency, sessions, stats, Database Mail, services
  security/         logins, users, orphans, permissions, encryption/TDE, CLR
  storage/          disk space, file sizes, log space, pre-growth, growth diagnostics, log shrink
powershell/         server-side troubleshooting and inventory scripts
robocopy/           backup file copy wrapper and Robocopy cheat sheet
cheatsheets/        quick references (T-SQL, sp_WhoIsActive, third-party tools)
```

## Script index

### T-SQL: Always On availability groups

| Script | What it does |
|---|---|
| [ag-replica-health.sql](tsql/alwayson/ag-replica-health.sql) | Role, sync state and health, send/redo queues, lag and last commit for every AG database |
| [ag-sync-lag.sql](tsql/alwayson/ag-sync-lag.sql) | Estimated data loss in seconds per database and secondary |
| [ag-failover-readiness.sql](tsql/alwayson/ag-failover-readiness.sql) | Pre-checks for a planned failover and prints the failover command |
| [ag-listeners.sql](tsql/alwayson/ag-listeners.sql) | Listener DNS names, ports, IPs and state |
| [ag-health-timeouts.sql](tsql/alwayson/ag-health-timeouts.sql) | Health check timeout, failure condition level and lease timeout, with change commands |
| [ag-automatic-seeding-status.sql](tsql/alwayson/ag-automatic-seeding-status.sql) | Automatic seeding history, failures and live progress |
| [read-only-routing-url.sql](tsql/alwayson/read-only-routing-url.sql) | Calculates the correct READ_ONLY_ROUTING_URL for an instance |
| [connection-strings-by-database.sql](tsql/alwayson/connection-strings-by-database.sql) | Suggested connection string per database (listener + MultiSubnetFailover for AG databases) |
| [create-availability-group-template.sql](tsql/alwayson/create-availability-group-template.sql) | SQLCMD-mode template to build a two-replica AG with a listener |
| [job-step-run-only-on-primary.sql](tsql/alwayson/job-step-run-only-on-primary.sql) | Guard step so a job only runs on the primary replica |
| [ag-health-monitoring/](tsql/alwayson/ag-health-monitoring) | Three scripts that log AG health every 15 minutes, purge old rows, and email a daily summary |

### T-SQL: Backup and restore

| Script | What it does |
|---|---|
| [backup-all-user-databases.sql](tsql/backup-restore/backup-all-user-databases.sql) | Full (COPY_ONLY by default) backup of every user database with compression and checksum |
| [generate-backup-and-restore-commands.sql](tsql/backup-restore/generate-backup-and-restore-commands.sql) | Generates matching BACKUP and RESTORE WITH MOVE commands for migrations and refreshes |
| [backup-history.sql](tsql/backup-restore/backup-history.sql) | Detailed backup history plus the latest full, diff and log per database |
| [backup-lsn-chain.sql](tsql/backup-restore/backup-lsn-chain.sql) | LSN chain for one database, to plan a restore or explain a refused one |
| [backup-restore-progress.sql](tsql/backup-restore/backup-restore-progress.sql) | Percent complete, ETA, waits and SQL text for running backups, restores and DBCC |
| [check-backup-file-exists.sql](tsql/backup-restore/check-backup-file-exists.sql) | Confirms SQL Server can see and read a backup file before you restore |

### T-SQL: Security and logins

| Script | What it does |
|---|---|
| [script-out-logins-sp_help_revlogin.sql](tsql/security/script-out-logins-sp_help_revlogin.sql) | Microsoft's sp_help_revlogin with server roles, to copy logins with original SIDs and passwords |
| [script-out-all-logins-roles-and-users.sql](tsql/security/script-out-all-logins-roles-and-users.sql) | Logins, server roles, and users/roles in every database in one script |
| [script-out-database-users-and-permissions.sql](tsql/security/script-out-database-users-and-permissions.sql) | Re-runnable script of one database's users, roles and permissions (run before a refresh) |
| [orphaned-users-find.sql](tsql/security/orphaned-users-find.sql) | Orphaned users in the current database and across all databases |
| [orphaned-users-fix.sql](tsql/security/orphaned-users-fix.sql) | Re-maps orphaned users to the matching login (ALTER USER WITH LOGIN) |
| [orphaned-users-drop.sql](tsql/security/orphaned-users-drop.sql) | Drops orphaned users, preview first |
| [database-permissions-report.sql](tsql/security/database-permissions-report.sql) | Direct, role-inherited and public permissions in a database |
| [logins-overview.sql](tsql/security/logins-overview.sql) | Logins with status, password policy, lock state and server roles |
| [database-users-and-roles-all-databases.sql](tsql/security/database-users-and-roles-all-databases.sql) | Every user and role membership in every database, for access reviews |
| [drop-login-with-active-sessions.sql](tsql/security/drop-login-with-active-sessions.sql) | Kills a login's sessions and drops it, preview first |
| [connections-auth-and-encryption.sql](tsql/security/connections-auth-and-encryption.sql) | Kerberos vs NTLM, TLS encryption and client IP for current connections |
| [encryption-tde-keys-and-certificates.sql](tsql/security/encryption-tde-keys-and-certificates.sql) | TDE status per database, certificate expiry, keys |
| [clr-assemblies-and-trustworthy.sql](tsql/security/clr-assemblies-and-trustworthy.sql) | CLR settings, TRUSTWORTHY databases and user assemblies |
| [failed-logins-and-locked-accounts.sql](tsql/security/failed-logins-and-locked-accounts.sql) | Failed logins from the default trace and error log, lock-out status, unlock commands |

### T-SQL: Monitoring

| Script | What it does |
|---|---|
| [blocking-chain.sql](tsql/monitoring/blocking-chain.sql) | Lead blockers and every blocked request with SQL text |
| [sessions-by-database-host-or-program.sql](tsql/monitoring/sessions-by-database-host-or-program.sql) | Who is connected, filtered by database, host, program or login |
| [cpu-utilization-history.sql](tsql/monitoring/cpu-utilization-history.sql) | SQL Server vs other process CPU, minute by minute for about 4 hours |
| [cpu-scheduler-pressure.sql](tsql/monitoring/cpu-scheduler-pressure.sql) | Runnable task queues and signal wait percentage |
| [memory-usage.sql](tsql/monitoring/memory-usage.sql) | OS and SQL Server memory, clerks and buffer pool by database |
| [file-io-latency.sql](tsql/monitoring/file-io-latency.sql) | Average read and write latency per database file |
| [index-operation-progress.sql](tsql/monitoring/index-operation-progress.sql) | Live progress and ETA of an index build or rebuild |
| [statistics-properties.sql](tsql/monitoring/statistics-properties.sql) | Last stats update, sample rate and modifications since |
| [windows-service-status.sql](tsql/monitoring/windows-service-status.sql) | SQL services plus any Windows service via xp_servicecontrol |
| [database-mail-check.sql](tsql/monitoring/database-mail-check.sql) | Mail profiles and SMTP servers, test email, recent items and errors |
| [python-r-external-scripts-check.sql](tsql/monitoring/python-r-external-scripts-check.sql) | Whether SQL Server itself uses Python or R (for vulnerability findings) |

### T-SQL: Storage

| Script | What it does |
|---|---|
| [disk-space-by-volume.sql](tsql/storage/disk-space-by-volume.sql) | Volume size and free space in GB, plus xp_fixeddrives |
| [disk-space-alert-check.sql](tsql/storage/disk-space-alert-check.sql) | Only the volumes below a free-space threshold |
| [database-file-sizes-and-free-space.sql](tsql/storage/database-file-sizes-and-free-space.sql) | Size, used, free and % used for every file, with growth settings |
| [log-space-and-reuse-wait.sql](tsql/storage/log-space-and-reuse-wait.sql) | Log size, % used and why the log will not truncate |
| [pre-grow-data-files.sql](tsql/storage/pre-grow-data-files.sql) | Pre-grows data files by a percentage with BEFORE and AFTER evidence for change records |
| [file-growth-diagnostic-toolkit.sql](tsql/storage/file-growth-diagnostic-toolkit.sql) | Autogrowth settings, growth trend, growth events, IFI and the fix |
| [shrink-log-files.sql](tsql/storage/shrink-log-files.sql) | Procedure to shrink log files to a target size, preview first |

### T-SQL: Agent jobs, maintenance and log shipping

| Script | What it does |
|---|---|
| [failed-jobs.sql](tsql/agent-jobs/failed-jobs.sql) | Job step failures in the last N days with error messages |
| [jobs-schedule-and-next-run.sql](tsql/agent-jobs/jobs-schedule-and-next-run.sql) | Every job with schedule, next run and last outcome |
| [job-steps-search.sql](tsql/agent-jobs/job-steps-search.sql) | Finds job steps that mention a keyword (remoting, xp_cmdshell, old servers) |
| [ola-hallengren-job-schedules.sql](tsql/agent-jobs/ola-hallengren-job-schedules.sql) | Schedules for the Ola Hallengren Maintenance Solution jobs |
| [add-primary-key-to-heaps.sql](tsql/maintenance/add-primary-key-to-heaps.sql) | Lists tables with no primary key and generates surrogate keys, preview first |
| [kill-sessions-for-database.sql](tsql/maintenance/kill-sessions-for-database.sql) | Clears connections from a database before a restore or rename |
| [schema-object-counts.sql](tsql/maintenance/schema-object-counts.sql) | Object counts and row counts to compare source and target after a migration |
| [log-shipping-status.sql](tsql/log-shipping/log-shipping-status.sql) | Last backup, copy and restore with minutes since each |

### PowerShell

| Script | What it does |
|---|---|
| [Test-SqlConnectivity.ps1](powershell/Test-SqlConnectivity.ps1) | DNS, TCP port on every resolved IP, and a real SQL login test |
| [Get-DiskSpace.ps1](powershell/Get-DiskSpace.ps1) | Size and free space of every volume and mount point on one or many servers |
| [Get-SqlServiceAccounts.ps1](powershell/Get-SqlServiceAccounts.ps1) | SQL-related services and their accounts across servers (WinRM with DCOM fallback) |
| [Test-ServiceStatus.ps1](powershell/Test-ServiceStatus.ps1) | Confirms a service is installed and running on every server in a list or CMDB export |
| [Get-WinRMActivity.ps1](powershell/Get-WinRMActivity.ps1) | Audits remote shell / WinRM use on servers before disabling it |
| [Get-ClusterNodeConfig.ps1](powershell/Get-ClusterNodeConfig.ps1) | Collects cluster, AG resource, network and NIC settings from a node |
| [Compare-ClusterNodeConfig.ps1](powershell/Compare-ClusterNodeConfig.ps1) | Side-by-side and differences-only comparison of any number of nodes |
| [Find-PythonRuntime.ps1](powershell/Find-PythonRuntime.ps1) | Finds Python runtimes on a server and which process has them loaded |
| [Get-SSMSInstallInfo.ps1](powershell/Get-SSMSInstallInfo.ps1) | Reports SSMS versions (including SSMS 21+) and upgrades in place |
| [Find-SSMSLeftoverFiles.ps1](powershell/Find-SSMSLeftoverFiles.ps1) | Scans for binaries left over from an old SSMS version after an upgrade |

### Robocopy

| File | What it does |
|---|---|
| [Copy-BackupFiles.ps1](robocopy/Copy-BackupFiles.ps1) | Robocopy wrapper for backup files: restartable, retries, logging, dry run, exit-code check |
| [robocopy-cheatsheet.md](robocopy/robocopy-cheatsheet.md) | Commands, switches, exit codes and the SQL Agent exit-code wrapper |

### Cheat sheets

| File | What it covers |
|---|---|
| [tsql-quick-reference.md](cheatsheets/tsql-quick-reference.md) | Everyday T-SQL and admin commands, and a few common misconceptions |
| [sp_whoisactive-usage.md](cheatsheets/sp_whoisactive-usage.md) | The sp_WhoIsActive parameter combinations I use most |
| [third-party-tools.md](cheatsheets/third-party-tools.md) | Community tools I rely on and where to get them |

## Running PowerShell scripts

```powershell
# Allow scripts for this session only
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
cd <path-to-this-repo>\powershell
Get-Help .\Get-DiskSpace.ps1 -Full
.\Get-DiskSpace.ps1 -ServerListPath .\servers.txt
```

Most scripts run on Windows PowerShell 5.1 and PowerShell 7. `Test-ServiceStatus.ps1`
needs Windows PowerShell 5.1 because it uses `Get-Service -ComputerName`.

## Requirements

* SQL Server 2016 or later unless a script's header says otherwise
* sysadmin or the specific permissions noted in the header
* Windows PowerShell 5.1 or PowerShell 7 for the PowerShell scripts
