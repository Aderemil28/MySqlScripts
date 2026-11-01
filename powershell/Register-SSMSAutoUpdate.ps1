<#
.SYNOPSIS
    Creates a scheduled task that runs Update-SSMS.ps1 against a list of servers every few weeks.

.DESCRIPTION
    Run once, elevated, on the machine that will do the updating (a management server, or the DC
    in a lab). Each run downloads the latest SSMS 22 bootstrapper and updates every server listed.
    Servers already on the newest build are left as they are (Before and After match in the log).
    Every run writes its own transcript log to -LogFolder.

    The start time is stored without a time zone offset, so the task keeps the same local time
    through daylight saving changes. Re-run the script to change the schedule or the account
    password; it replaces the existing task.

.PARAMETER ComputerName
    Servers to keep updated.

.PARAMETER ScriptPath
    Where Update-SSMS.ps1 lives on this machine.

.PARAMETER WeeksInterval
    Run every N weeks.

.PARAMETER DayOfWeek
    Day the task runs.

.PARAMETER At
    Local time the task runs.

.EXAMPLE
    .\Register-SSMSAutoUpdate.ps1 -ComputerName SQLNODE01, SQLNODE02, SQLNODE03, SQLNODE04

.EXAMPLE
    .\Register-SSMSAutoUpdate.ps1 -ComputerName SQLNODE01, SQLNODE02 -WeeksInterval 2 -DayOfWeek Saturday -At '2:00AM'

.NOTES
    Prompts for the account the task runs as (DOMAIN\user). It must be local admin on every server.
    Avoid using a SQL Server service account; a password change would break SQL and the task together.
    The task runs Update-SSMS.ps1 with -Execute -Force, so SSMS is closed on a server if left open.
    Pick a quiet time.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string[]]$ComputerName,
    [string]$ScriptPath = 'C:\Scripts\Update-SSMS.ps1',
    [ValidateSet('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday')]
    [string]$DayOfWeek = 'Sunday',
    [string]$At = '3:00AM',
    [ValidateRange(1, 52)]
    [int]$WeeksInterval = 3,
    [string]$LogFolder = 'C:\Scripts\Logs_SSMS',
    [string]$TaskName = 'SSMS Auto Update'
)

if (-not (Test-Path $ScriptPath)) {
    throw "Can't find $ScriptPath. Pass the right location with -ScriptPath."
}
New-Item -Path $LogFolder -ItemType Directory -Force | Out-Null

$cred = Get-Credential -Message 'Account that is local admin on all servers (DOMAIN\username)'

$serverList = $ComputerName -join ','

# Get-Date is evaluated at run time, so each run gets its own log file.
# -Command (not -File) so the comma-separated server list arrives as an array.
$cmd = "Start-Transcript -Path (Join-Path '$LogFolder' ('SSMS-Update_' + (Get-Date -Format yyyyMMdd_HHmm) + '.log')); " +
       "& '$ScriptPath' -ComputerName $serverList -Execute -Force; " +
       "Stop-Transcript"

$action   = New-ScheduledTaskAction -Execute 'powershell.exe' `
              -Argument "-NoProfile -ExecutionPolicy Bypass -Command `"$cmd`""
$trigger  = New-ScheduledTaskTrigger -Weekly -WeeksInterval $WeeksInterval -DaysOfWeek $DayOfWeek -At $At

# Keep the same local time through daylight saving changes (no 2 AM / 3 AM shift)
$trigger.StartBoundary = (Get-Date $At).ToString('yyyy-MM-ddTHH:mm:ss')

$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RunOnlyIfNetworkAvailable `
              -ExecutionTimeLimit (New-TimeSpan -Hours 2)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
    -User $cred.UserName -Password $cred.GetNetworkCredential().Password `
    -RunLevel Highest -Force | Out-Null

$next = (Get-ScheduledTaskInfo -TaskName $TaskName).NextRunTime
Write-Host "Scheduled task '$TaskName' saved: every $WeeksInterval week(s) on $DayOfWeek at $At." -ForegroundColor Green
Write-Host "Next run: $next"
Write-Host "Servers:  $serverList"
Write-Host "Logs:     $LogFolder"
Write-Host "Test it now with:  Start-ScheduledTask -TaskName '$TaskName'"
