# T-SQL quick reference

Everyday commands I reach for. Replace the placeholder names before running.

## Querying

| Task | Command |
|---|---|
| All rows and columns | `SELECT * FROM dbo.TableName;` |
| Specific columns | `SELECT Column1, Column2, Column3 FROM dbo.TableName;` |
| Filter rows | `SELECT * FROM dbo.TableName WHERE Country = 'Canada';` |
| Greater than | `SELECT Column1, Column2 FROM dbo.TableName WHERE Quantity > 10;` |
| Not equal | `SELECT Column1, Column2 FROM dbo.TableName WHERE Quantity <> 10;` |
| Sort | `SELECT Column1, Column2 FROM dbo.TableName ORDER BY Column1 ASC;` (or `DESC`) |
| Copy a table (structure + data, no indexes or keys) | `SELECT * INTO dbo.TableName_copy FROM dbo.TableName;` |

## Indexes

| Task | Command |
|---|---|
| Create a clustered index | `CREATE CLUSTERED INDEX CIX_TableName_Column ON dbo.TableName (ColumnName);` |
| Drop a nonclustered index | `DROP INDEX NCIX_TableName_Column ON dbo.TableName;` |
| Index recommendations (First Responder Kit) | `EXEC dbo.sp_BlitzIndex @DatabaseName = N'YourDatabase';` |

## Databases and recovery

| Task | Command |
|---|---|
| Recovery model of user databases | `SELECT name, recovery_model_desc FROM sys.databases WHERE database_id > 4;` |
| Change recovery model | `ALTER DATABASE [YourDatabase] SET RECOVERY SIMPLE;` (breaks the log backup chain; take a full backup after switching back to FULL) |
| Log size and % used, all databases | `DBCC SQLPERF(LOGSPACE);` |
| Why the log will not truncate | `SELECT name, log_reuse_wait_desc FROM sys.databases;` |
| Look inside a backup file | `RESTORE HEADERONLY FROM DISK = N'X:\SQLBackups\YourDatabase_FULL.bak';` |
| Files inside a backup | `RESTORE FILELISTONLY FROM DISK = N'X:\SQLBackups\YourDatabase_FULL.bak';` |

## Sessions

| Task | Command |
|---|---|
| Who is running what | `EXEC sp_WhoIsActive;` (or `EXEC sp_who2;` if it is not installed) |
| Sessions in one database | `SELECT session_id, login_name, host_name, program_name FROM sys.dm_exec_sessions WHERE database_id = DB_ID('YourDatabase');` |
| Count of active log records (diagnostic only, undocumented) | `SELECT COUNT(*) FROM fn_dblog(NULL, NULL);` |

## Windows accounts and AD groups

| Task | Command |
|---|---|
| Which AD groups give a user access | `EXEC xp_logininfo 'DOMAIN\UserName', 'all';` |
| Members of an AD group login | `EXEC xp_logininfo 'DOMAIN\GroupName', 'members';` |

## Things that are often misunderstood

* `DBCC FREEPROCCACHE` clears the **plan cache for the whole instance**. Every query recompiles afterwards, which causes a CPU spike. It does **not** free tempdb space. Only use it deliberately, and prefer clearing one plan: `DBCC FREEPROCCACHE (plan_handle);`
* To free tempdb, find what is using it first (`sys.dm_db_session_space_usage`, `sys.dm_db_task_space_usage`). Shrinking tempdb while it is busy rarely works. A service restart recreates tempdb at its configured size.
* `fn_dblog` reads the active portion of the log. It is undocumented and should not be run on a busy production database.
