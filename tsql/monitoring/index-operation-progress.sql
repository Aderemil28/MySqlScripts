/*
Script  : index-operation-progress.sql
Purpose : Live progress of an index create, rebuild or other long scan/sort for a
          given session: rows processed, percent complete and an ETA.
Usage   : Set @SPID to the session running the index operation
          (find it with sp_WhoIsActive or sys.dm_exec_requests).
Changes : Read-only.
Requires: SQL Server 2016 SP1 and later. Needs lightweight query profiling,
          which is on by default from SQL Server 2019. On 2016/2017 enable
          trace flag 7412 or start the query with SET STATISTICS PROFILE ON.
*/
DECLARE @SPID int = 0;   -- session running the index operation

WITH agg AS
(
    SELECT
        SUM(qp.row_count)                                    AS RowsProcessed,
        SUM(qp.estimate_row_count)                           AS TotalRows,
        MAX(qp.last_active_time) - MIN(qp.first_active_time) AS ElapsedMS,
        MAX(IIF(qp.close_time = 0 AND qp.first_row_time > 0, qp.physical_operator_name, N'<Transition>')) AS CurrentStep
    FROM sys.dm_exec_query_profiles AS qp
    WHERE qp.physical_operator_name IN (N'Table Scan', N'Clustered Index Scan', N'Index Scan', N'Sort')
      AND qp.session_id = @SPID
),
comp AS
(
    SELECT *,
           TotalRows - RowsProcessed AS RowsLeft,
           ElapsedMS / 1000.0        AS ElapsedSeconds
    FROM agg
)
SELECT
    CurrentStep,
    TotalRows,
    RowsProcessed,
    RowsLeft,
    CONVERT(decimal(5,2), RowsProcessed * 100.0 / NULLIF(TotalRows, 0))              AS PercentComplete,
    ElapsedSeconds,
    ElapsedSeconds / NULLIF(RowsProcessed, 0) * RowsLeft                             AS EstimatedSecondsLeft,
    DATEADD(SECOND, ElapsedSeconds / NULLIF(RowsProcessed, 0) * RowsLeft, GETDATE()) AS EstimatedCompletionTime
FROM comp;
