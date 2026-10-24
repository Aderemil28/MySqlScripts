# Robocopy cheat sheet for DBAs

`Copy-BackupFiles.ps1` in this folder wraps the common case with logging and an
exit-code check. These are the raw commands for quick use.

## Common commands

```bat
:: Dry run first: list what would be copied, copy nothing
robocopy X:\SQLBackups\AppDB \\drserver\SQLBackups\AppDB *.bak /L /NP

:: Copy one large backup file, restartable, sane retries, with a log
robocopy X:\SQLBackups\AppDB \\drserver\SQLBackups\AppDB AppDB_FULL_20261024.bak /Z /R:3 /W:10 /NP /LOG:C:\Temp\robocopy_appdb.log

:: Copy all .bak and .trn files changed in the last 2 days, 8 threads
robocopy X:\SQLBackups \\drserver\SQLBackups *.bak *.trn /S /MAXAGE:2 /MT:8 /R:3 /W:10 /NP /LOG:C:\Temp\robocopy_backups.log

:: Append to an existing log instead of overwriting it
robocopy X:\SQLBackups \\drserver\SQLBackups *.trn /MAXAGE:1 /R:3 /W:10 /NP /LOG+:C:\Temp\robocopy_trn.log

:: Mirror a folder (DELETES files at the destination that are not in the source)
robocopy X:\Scripts \\fileserver\DBA\Scripts /MIR /R:2 /W:5 /NP /LOG:C:\Temp\robocopy_mirror.log

:: Move instead of copy (deletes the source files after a successful copy)
robocopy X:\SQLBackups\Old \\archive\SQLBackups\Old *.bak /MOV /R:3 /W:10 /NP
```

## Switches worth knowing

| Switch | What it does |
|---|---|
| `/L` | List only (dry run). Always start here with `/MIR` or `/MOV`. |
| `/Z` | Restartable mode. Resumes a large file after a network drop. |
| `/J` | Unbuffered I/O. Faster and lighter on memory for very large files (multi-GB backups). |
| `/MT:n` | Multithreaded copy (default 8). Helps with many files; little gain for one big file. |
| `/R:n /W:n` | Retries and wait between retries. **Always set these**; the defaults (1,000,000 retries, 30 s) can hang for weeks on a locked file. |
| `/S` / `/E` | Include subfolders (`/E` also copies empty ones). |
| `/MAXAGE:n` | Only files modified in the last n days (or since a yyyymmdd date). |
| `/XF` / `/XD` | Exclude files / folders, for example `/XF *.tmp`. |
| `/COPY:DAT` | Copy data, attributes and timestamps only. Use `/COPY:DATSOU` to keep NTFS permissions, owner and auditing. |
| `/MIR` | Mirror. Equivalent to `/E /PURGE`; deletes extra destination files. |
| `/MOV` | Move files (delete from source after copy). |
| `/NP` | No per-file percentage, keeps logs readable. |
| `/LOG:file` `/LOG+:file` | Write (or append) a log. |
| `/TEE` | Show output on screen as well as in the log. |
| `/IPG:ms` | Inter-packet gap, throttles bandwidth on a busy WAN link. |

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Nothing copied; already in sync |
| 1 | Files copied successfully |
| 2 | Extra files at the destination; nothing failed |
| 3 | Copied, plus extra files at the destination |
| 4 to 7 | Mismatches present; review the log |
| 8 and above | **At least one copy failed** |

In a SQL Agent CmdExec step, Robocopy's exit code 1 makes the step "fail" by
default. Wrap it so only 8+ fails the step:

```bat
robocopy X:\SQLBackups \\drserver\SQLBackups *.bak /MAXAGE:1 /R:3 /W:10 /NP /LOG:C:\Temp\robocopy_job.log
IF %ERRORLEVEL% LSS 8 EXIT /B 0
EXIT /B %ERRORLEVEL%
```

## Checks before a big copy

* Free space on the destination: `Get-DiskSpace.ps1 -ComputerName drserver` (in the powershell folder).
* Permissions: the account running Robocopy needs write on the destination; the
  SQL Server service account needs read there if you will restore from it.
* Confirm the backup is good before moving it: `RESTORE VERIFYONLY ... WITH CHECKSUM`.
