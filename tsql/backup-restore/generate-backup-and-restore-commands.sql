/*
Script  : generate-backup-and-restore-commands.sql
Purpose : Generates a COPY_ONLY backup command and a matching RESTORE ... WITH MOVE
          command for each user database. Handy for migrations and refreshes,
          where the restore runs on a different server with different drive letters.
Usage   : Set the three paths, run, and copy the two output columns.
          Nothing is executed. Review the RESTORE commands before running them
          on the target, because they use REPLACE.
Changes : Read-only. Output is text only.
Requires: SQL Server 2016 and later.
*/
SET NOCOUNT ON;

DECLARE @BackupPath  nvarchar(260) = N'X:\SQLBackups\';  -- where the .bak files are written and read
DECLARE @DataPath    nvarchar(260) = N'D:\SQLData\';     -- target data file folder
DECLARE @LogPath     nvarchar(260) = N'L:\SQLLogs\';     -- target log file folder
DECLARE @DatabaseLike sysname      = N'%';                -- filter, for example N'Sales%'

DECLARE @date char(8) = CONVERT(char(8), GETDATE(), 112);

WITH MoveCmd AS
(
    SELECT
        d.database_id,
        STUFF((
            SELECT N', MOVE N''' + mf.name + N''' TO N'''
                 + CASE WHEN mf.type = 1 THEN @LogPath ELSE @DataPath END
                 + RIGHT(mf.physical_name, CHARINDEX(N'\', REVERSE(mf.physical_name)) - 1) + N''''
            FROM sys.master_files AS mf
            WHERE mf.database_id = d.database_id
              AND mf.type IN (0, 1)              -- data and log files
            ORDER BY mf.file_id
            FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'') AS MoveList
    FROM sys.databases AS d
)
SELECT
    d.name AS database_name,
    N'BACKUP DATABASE ' + QUOTENAME(d.name) + N' TO DISK = N''' + @BackupPath + d.name + N'_COPY_ONLY_' + @date
        + N'.bak'' WITH COPY_ONLY, COMPRESSION, CHECKSUM, STATS = 10;' AS backup_command,
    N'RESTORE DATABASE ' + QUOTENAME(d.name) + N' FROM DISK = N''' + @BackupPath + d.name + N'_COPY_ONLY_' + @date
        + N'.bak'' WITH ' + m.MoveList + N', RECOVERY, REPLACE, STATS = 10;' AS restore_command
FROM sys.databases AS d
JOIN MoveCmd AS m ON m.database_id = d.database_id
WHERE d.database_id > 4                       -- user databases only
  AND d.name LIKE @DatabaseLike
ORDER BY d.name;
