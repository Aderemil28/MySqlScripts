<#
.SYNOPSIS
    Copies SQL Server backup files between servers or to a file share with
    Robocopy, with logging, restartable mode, retries, and a proper success check.

.DESCRIPTION
    Wraps robocopy.exe for the copies a DBA does all the time: moving .bak/.trn
    files for a migration or refresh, staging backups at the DR site, or
    pulling a backup to a dev server.
      - /Z restartable mode, so a dropped connection resumes instead of starting over
      - optional /J unbuffered I/O for very large files (-Unbuffered)
      - /MT multithreaded copy for many files
      - /R and /W retry settings that will not hang for hours (defaults are 1 million retries)
      - log file per run, and a readable verdict from the exit code
    Robocopy exit codes below 8 mean success (0 = nothing to copy, 1 = copied,
    2/3 = extra files present). 8 and above mean something failed.

.PARAMETER Source
    Source folder (local path or UNC).

.PARAMETER Destination
    Destination folder (local path or UNC). Created if missing.

.PARAMETER Files
    File name filter(s), for example '*.bak' or 'AppDB_FULL_*.bak'.

.PARAMETER MaxAgeDays
    Only copy files modified in the last N days (0 = no age filter).

.PARAMETER Mirror
    Make the destination an exact copy of the source (/MIR). DELETES destination
    files that are not in the source. Use with care.

.PARAMETER Unbuffered
    Adds /J (unbuffered I/O). Faster and lighter on memory for multi-GB backup files.

.PARAMETER DryRun
    List what would be copied without copying (/L).

.EXAMPLE
    .\Copy-BackupFiles.ps1 -Source 'X:\SQLBackups\AppDB' -Destination '\\drserver\SQLBackups\AppDB' -Files '*.bak' -DryRun
    .\Copy-BackupFiles.ps1 -Source 'X:\SQLBackups\AppDB' -Destination '\\drserver\SQLBackups\AppDB' -Files '*.bak','*.trn' -MaxAgeDays 2

.NOTES
    The account running this needs read on the source and write on the destination.
    When SQL Server will restore from the destination, the SQL Server service
    account also needs read access there.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$Destination,
    [string[]]$Files = @('*.bak'),
    [int]$MaxAgeDays = 0,
    [int]$Threads = 8,
    [int]$Retries = 3,
    [int]$WaitSeconds = 10,
    [string]$LogFolder = 'C:\Temp\RobocopyLogs',
    [switch]$Unbuffered,
    [switch]$Mirror,
    [switch]$DryRun
)

if (-not (Test-Path $Source)) { throw "Source not found: $Source" }
if (-not (Test-Path $LogFolder)) { New-Item -ItemType Directory -Path $LogFolder | Out-Null }

$log = Join-Path $LogFolder ("robocopy_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

$rcArgs = @($Source, $Destination) + $Files + @(
    '/Z',                 # restartable
    "/MT:$Threads",       # multithreaded
    "/R:$Retries",        # retries per file
    "/W:$WaitSeconds",    # seconds between retries
    '/COPY:DAT',          # data, attributes, timestamps (no ACLs, owner or audit info)
    '/DCOPY:T',           # keep folder timestamps
    '/NP',                # no per-file progress % (keeps the log readable)
    '/TEE',               # write to console and log
    "/LOG:$log"
)
if ($MaxAgeDays -gt 0) { $rcArgs += "/MAXAGE:$MaxAgeDays" }
if ($Unbuffered)       { $rcArgs += '/J' }
if ($Mirror)           { $rcArgs += '/MIR' }
if ($DryRun)           { $rcArgs += '/L' }

Write-Host "robocopy $($rcArgs -join ' ')" -ForegroundColor Cyan
& robocopy.exe @rcArgs
$code = $LASTEXITCODE

$meaning = switch ($code) {
    0       { 'No files copied: source and destination already in sync.' }
    1       { 'Files copied successfully.' }
    2       { 'Extra files or folders found at the destination. Nothing failed.' }
    3       { 'Files copied, and extra files found at the destination.' }
    { $_ -ge 4 -and $_ -lt 8 } { 'Completed with mismatches. Review the log.' }
    default { 'FAILED: at least one file could not be copied. Check the log.' }
}

if ($code -lt 8) { Write-Host "Exit code $code - $meaning" -ForegroundColor Green }
else             { Write-Host "Exit code $code - $meaning" -ForegroundColor Red }
Write-Host "Log: $log"

exit $code
