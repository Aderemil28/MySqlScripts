# sp_WhoIsActive usage

`sp_WhoIsActive` is Adam Machanic's free activity monitoring procedure. It is not
included in this repo; install the latest release from the official source:

* Releases: <https://github.com/amachanic/sp_whoisactive/releases>
* Docs: <http://whoisactive.com>

## Commands I use

```sql
-- Built-in help with every parameter
EXEC sp_WhoIsActive @help = 1;

-- Default view: what is running right now
EXEC sp_WhoIsActive;

-- Memory grant information
EXEC sp_WhoIsActive @get_memory_info = 1;

-- Extra detail (SET options, Agent job name, lock timeouts and more)
EXEC sp_WhoIsActive @get_additional_info = 1;

-- Lead blocker
EXEC sp_WhoIsActive @find_block_leaders = 1;

-- What changed over 5 seconds (CPU, reads, writes deltas)
EXEC sp_WhoIsActive @delta_interval = 5, @output_column_list = '[%delta][%]';

-- Task level waits, useful for parallelism (CXPACKET / CXCONSUMER)
EXEC sp_WhoIsActive @get_task_info = 2;

-- Whole batch plan instead of the current statement's plan
EXEC sp_WhoIsActive @get_plans = 2;

-- Average duration of previous runs of the same query
EXEC sp_WhoIsActive @get_avg_time = 1;

-- Choose which columns come first
EXEC sp_WhoIsActive @output_column_list = '[session_id][block%][login%][%]';

-- Lead blocker at the top
EXEC sp_WhoIsActive
     @output_column_list = '[session_id][block%][login%][%]',
     @find_block_leaders = 1,
     @sort_order = '[blocked_session_count] DESC';

-- Blocking with lock detail
EXEC sp_WhoIsActive
     @output_column_list = '[session_id][block%][login%][locks][%]',
     @find_block_leaders = 1,
     @sort_order = '[blocked_session_count] DESC',
     @get_locks = 1;

-- Blocking with isolation level and other session detail
EXEC sp_WhoIsActive
     @output_column_list = '[session_id][block%][login%][additional%][%]',
     @find_block_leaders = 1,
     @sort_order = '[blocked_session_count] DESC',
     @get_additional_info = 1;
```

If it is not installed, `tsql/monitoring/blocking-chain.sql` gives a basic blocking view.
