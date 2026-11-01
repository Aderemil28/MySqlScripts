<#
.SYNOPSIS
    AG-aware Windows patching: secondary first, planned failover, then the old primary.
    Works with plain availability groups and with two AGs linked by a distributed AG.

.DESCRIPTION
    Patches the nodes of each availability group one at a time:

      1. With a distributed AG, the AG on the DAG secondary side is patched first and the AG on the
         global primary side last. The order is worked out at run time from the live roles.
      2. Within each AG:
           a. Pre-check: AG healthy, every database SYNCHRONIZED, DAG healthy. If not, stop.
           b. Patch the SECONDARY. Reboot only if Windows says a reboot is needed.
              Wait for SQL Server to come back and the AG to resync.
           c. Check whether the PRIMARY has anything to install. If not, no failover happens.
           d. Planned failover to the freshly patched node (ALTER AVAILABILITY GROUP ... FAILOVER).
           e. Patch the old primary (now the secondary), reboot if needed, wait for resync.
           f. Fail back to the original primary (unless -NoFailBack).
      3. Any failure stops the whole run. Nothing is retried or skipped past.
      4. Ends with a summary and, if Get-AGStatusReport.ps1 is in the same folder, the AG status report.

    Updates come from whatever each node is already set up to use (Windows Update or WSUS).
    Titles matching -ExcludeTitleLike are skipped. The defaults skip SQL Server updates (patch those
    with Invoke-SQLPatching.ps1) and Defender definition updates (Defender installs those itself,
    several times a day, with no reboot; including them would cause a failover on every run).

    The Windows Update API refuses to download or install from a remote PowerShell session, so each
    node installs through a one-time scheduled task running as SYSTEM, and the script polls for the result.

.PARAMETER AvailabilityGroups
    One hashtable per AG with its name and nodes, for example:
      @{ Name = 'AG1'; Nodes = 'SQLNODE01','SQLNODE02' }, @{ Name = 'AG2'; Nodes = 'SQLNODE03','SQLNODE04' }

.PARAMETER DagName
    Name of the distributed AG linking the AGs above. Leave empty if there is none.

.PARAMETER SqlPort
    TCP port the instances listen on. Connections go straight to tcp:<node>,<port>.

.PARAMETER Execute
    Without it the script only reports: roles, health, and the updates each node would get.
    With it, it installs, fails over and reboots.

.PARAMETER NoFailBack
    Leave each AG on whichever node it ends up on instead of failing back to the original primary.

.PARAMETER ExcludeTitleLike
    Update titles to skip (wildcards).

.EXAMPLE
    # Dry run (default)
    $ags = @{ Name = 'AG1'; Nodes = 'SQLNODE01','SQLNODE02' }, @{ Name = 'AG2'; Nodes = 'SQLNODE03','SQLNODE04' }
    .\Invoke-AGPatching.ps1 -AvailabilityGroups $ags -DagName 'DAG1'

.EXAMPLE
    # Real run
    .\Invoke-AGPatching.ps1 -AvailabilityGroups $ags -DagName 'DAG1' -Execute

.NOTES
    RUN IT FROM A MACHINE THAT IS NOT ONE OF THE NODES (a management server or the DC in a lab),
    because it reboots the nodes. The script refuses to run on a node.
    The account needs local admin on every node (remoting, updates, reboots) and sysadmin on every
    instance (health checks and failovers). PowerShell remoting (WinRM) must be enabled on the nodes.
    Two-node AGs only (one primary, one secondary per AG).
    Windows PowerShell 5.1.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [hashtable[]]$AvailabilityGroups,
    [string]$DagName,
    [int]$SqlPort = 1433,
    [switch]$Execute,
    [switch]$NoFailBack,
    [string[]]$ExcludeTitleLike = @('*SQL Server*', '*Security Intelligence Update*'),
    [int]$SyncTimeoutMinutes = 30,
    [int]$InstallTimeoutMinutes = 120,
    [string]$LogFolder = 'C:\Scripts\Logs_Patch'
)

$ErrorActionPreference = 'Stop'
$ReportOnly = -not $Execute
New-Item -Path $LogFolder -ItemType Directory -Force | Out-Null
$logFile = Join-Path $LogFolder ("AG-Patching_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmm'))
Start-Transcript -Path $logFile | Out-Null

$script:Summary = New-Object System.Collections.Generic.List[object]

# ---------------------------------------------------------------- helpers

function Write-Log {
    param([string]$Message, [string]$Color = 'Gray')
    Write-Host ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -ForegroundColor $Color
}

function Invoke-Sql {
    param([string]$Server, [string]$Query)
    $conn = New-Object System.Data.SqlClient.SqlConnection "Server=tcp:$Server,$SqlPort;Database=master;Integrated Security=True;Connect Timeout=15;Application Name=AGPatching"
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $Query
        $cmd.CommandTimeout = 120
        $table = New-Object System.Data.DataTable
        $table.Load($cmd.ExecuteReader())
        $table.Rows
    }
    finally { $conn.Dispose() }
}

function Invoke-SqlNonQuery {
    param([string]$Server, [string]$Query)
    $conn = New-Object System.Data.SqlClient.SqlConnection "Server=tcp:$Server,$SqlPort;Database=master;Integrated Security=True;Connect Timeout=15;Application Name=AGPatching"
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $Query
        $cmd.CommandTimeout = 300
        [void]$cmd.ExecuteNonQuery()
    }
    finally { $conn.Dispose() }
}

function Wait-Until {
    param([scriptblock]$Condition, [int]$TimeoutMinutes, [string]$What)
    $wuDeadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $wuDeadline) {
        $wuOk = $false
        try { $wuOk = [bool](& $Condition) } catch { $wuOk = $false }
        if ($wuOk) { Write-Log "${What}: OK" 'Green'; return }
        Start-Sleep -Seconds 20
    }
    throw "Timed out after $TimeoutMinutes minutes waiting for: $What"
}

# ---------------------------------------------------------------- AG / DAG state

function Get-NodeRole {
    param([string]$Node, [string]$AG)
    $rows = @(Invoke-Sql $Node "SELECT ars.role_desc FROM sys.dm_hadr_availability_replica_states ars JOIN sys.availability_groups ag ON ars.group_id = ag.group_id WHERE ag.name = N'$AG' AND ars.is_local = 1;")
    if ($rows.Count) { $rows[0].role_desc } else { 'UNKNOWN' }
}

function Get-AGPrimary {
    param([string]$AG, [string[]]$Nodes)
    foreach ($n in $Nodes) {
        try { if ((Get-NodeRole $n $AG) -eq 'PRIMARY') { return $n } } catch { }
    }
    throw "Could not find a PRIMARY for $AG on: $($Nodes -join ', ')"
}

function Test-AGHealthy {
    param([string]$Primary, [string]$AG)
    $q = @"
SELECT
 (SELECT gs.synchronization_health_desc FROM sys.dm_hadr_availability_group_states gs
    JOIN sys.availability_groups ag ON gs.group_id = ag.group_id WHERE ag.name = N'$AG') AS AGHealth,
 (SELECT COUNT(*) FROM sys.dm_hadr_database_replica_states drs
    JOIN sys.availability_groups ag ON drs.group_id = ag.group_id
    WHERE ag.name = N'$AG' AND drs.synchronization_state_desc <> 'SYNCHRONIZED') AS NotSynced,
 (SELECT COUNT(*) FROM sys.dm_hadr_availability_replica_states ars
    JOIN sys.availability_groups ag ON ars.group_id = ag.group_id
    WHERE ag.name = N'$AG' AND ars.connected_state_desc <> 'CONNECTED') AS NotConnected;
"@
    $r = @(Invoke-Sql $Primary $q)[0]
    ($r.AGHealth -eq 'HEALTHY') -and ($r.NotSynced -eq 0) -and ($r.NotConnected -eq 0)
}

function Get-DagRole {
    # Run on an AG's primary: is this AG the DAG global primary or the DAG secondary?
    param([string]$Primary, [string]$AG)
    if (-not $DagName) { return 'NONE' }
    $rows = @(Invoke-Sql $Primary "SELECT ars.role_desc FROM sys.dm_hadr_availability_replica_states ars JOIN sys.availability_replicas ar ON ars.replica_id = ar.replica_id JOIN sys.availability_groups ag ON ar.group_id = ag.group_id WHERE ag.name = N'$DagName' AND ar.replica_server_name = N'$AG';")
    if ($rows.Count) { $rows[0].role_desc } else { 'UNKNOWN' }
}

function Get-DagGlobalPrimaryNode {
    foreach ($ag in $AvailabilityGroups) {
        $p = Get-AGPrimary $ag.Name $ag.Nodes
        if ((Get-DagRole $p $ag.Name) -eq 'PRIMARY') { return $p }
    }
    throw "Could not find the global primary for $DagName."
}

function Test-DagHealthy {
    if (-not $DagName) { return $true }
    $gp = Get-DagGlobalPrimaryNode
    $r = @(Invoke-Sql $gp "SELECT COUNT(*) AS Bad FROM sys.dm_hadr_availability_replica_states ars JOIN sys.availability_groups ag ON ars.group_id = ag.group_id WHERE ag.name = N'$DagName' AND (ars.connected_state_desc <> 'CONNECTED' OR ars.synchronization_health_desc <> 'HEALTHY');")[0]
    $r.Bad -eq 0
}

# ---------------------------------------------------------------- Windows Update on a node

# Runs on the node as SYSTEM through a one-time scheduled task.
$installScript = @'
param([string]$Mode, [string]$ResultPath, [string]$Exclude)
$excludeList = @($Exclude -split '\|' | Where-Object { $_ })
$result = [ordered]@{ Mode = $Mode; Found = 0; Titles = @(); ResultCode = $null; RebootRequired = $false; Error = $null; Finished = $null }
try {
    $session  = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $search   = $searcher.Search("IsInstalled=0 and Type='Software' and IsHidden=0")
    $coll = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $search.Updates) {
        $skip = $false
        foreach ($p in $excludeList) { if ($u.Title -like $p) { $skip = $true } }
        if (-not $skip) {
            if (-not $u.EulaAccepted) { $u.AcceptEula() }
            [void]$coll.Add($u)
        }
    }
    $result.Found  = $coll.Count
    $result.Titles = @(foreach ($u in $coll) { $u.Title })
    if ($Mode -eq 'Install' -and $coll.Count -gt 0) {
        $dl = $session.CreateUpdateDownloader(); $dl.Updates = $coll; [void]$dl.Download()
        $inst = $session.CreateUpdateInstaller(); $inst.Updates = $coll
        $r = $inst.Install()
        $result.ResultCode     = $r.ResultCode
        $result.RebootRequired = $r.RebootRequired
    }
}
catch { $result.Error = $_.Exception.Message }
$pending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
           (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
if ($pending) { $result.RebootRequired = $true }
$result.Finished = (Get-Date).ToString('s')
$result | ConvertTo-Json -Depth 3 | Set-Content -Path "$ResultPath.tmp" -Encoding UTF8
Move-Item -Path "$ResultPath.tmp" -Destination $ResultPath -Force
'@

function Invoke-NodeUpdates {
    param([string]$Node, [ValidateSet('Scan', 'Install')][string]$Mode)
    $excl = $ExcludeTitleLike -join '|'

    Invoke-Command -ComputerName $Node -ArgumentList $installScript, $Mode, $excl -ScriptBlock {
        param($scriptText, $mode, $excl)
        $dir = 'C:\Temp\Patch'
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
        $scriptPath = Join-Path $dir 'Install-Updates.ps1'
        $resultPath = Join-Path $dir 'result.json'
        Set-Content -Path $scriptPath -Value $scriptText -Encoding UTF8
        Remove-Item $resultPath -ErrorAction SilentlyContinue
        $taskArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -Mode $mode -ResultPath `"$resultPath`""
        if ($excl) { $taskArgs += " -Exclude `"$excl`"" }
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $taskArgs
        Register-ScheduledTask -TaskName 'AGPatching-WU' -Action $action -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
        Start-ScheduledTask -TaskName 'AGPatching-WU'
    }

    $deadline = (Get-Date).AddMinutes($InstallTimeoutMinutes)
    $json = $null
    do {
        Start-Sleep -Seconds 30
        $json = Invoke-Command -ComputerName $Node -ScriptBlock { Get-Content 'C:\Temp\Patch\result.json' -Raw -ErrorAction SilentlyContinue }
    } until ($json -or (Get-Date) -gt $deadline)

    Invoke-Command -ComputerName $Node -ScriptBlock { Unregister-ScheduledTask -TaskName 'AGPatching-WU' -Confirm:$false -ErrorAction SilentlyContinue }

    if (-not $json) { throw "Windows Update on $Node did not finish within $InstallTimeoutMinutes minutes." }
    $res = $json | ConvertFrom-Json
    if ($res.Error) { throw "Windows Update on $Node failed: $($res.Error)" }
    if ($Mode -eq 'Install' -and $res.Found -gt 0 -and $res.ResultCode -notin 2, 3) {
        throw "Windows Update on $Node returned result code $($res.ResultCode) (2 = succeeded, 3 = succeeded with errors, 4 = failed)."
    }
    $res
}

function Update-Node {
    # Patch one node that is currently a SECONDARY, reboot if needed, and wait for the AG to resync.
    param([string]$Node, [string]$AG, [string]$Primary)

    $role = Get-NodeRole $Node $AG
    if ($role -ne 'SECONDARY') { throw "$Node is $role for $AG, not SECONDARY. Refusing to patch it." }

    Write-Log "[$Node] Installing updates (secondary for $AG)..." 'Cyan'
    $res = Invoke-NodeUpdates $Node 'Install'
    if ($res.Found -gt 0) { $res.Titles | ForEach-Object { Write-Log "[$Node]   $_" } }
    else { Write-Log "[$Node] No updates to install." }

    $rebooted = $false
    if ($res.RebootRequired) {
        Write-Log "[$Node] Rebooting..." 'Yellow'
        Restart-Computer -ComputerName $Node -Force -Wait -For PowerShell -Timeout 3600 -Delay 15
        $rebooted = $true
        Wait-Until -What "[$Node] SQL Server back online" -TimeoutMinutes $SyncTimeoutMinutes -Condition {
            @(Invoke-Sql $Node 'SELECT 1 AS Up;').Count -eq 1
        }
    }

    Wait-Until -What "[$AG] healthy and SYNCHRONIZED after patching $Node" -TimeoutMinutes $SyncTimeoutMinutes -Condition {
        Test-AGHealthy $Primary $AG
    }

    $script:Summary.Add([pscustomobject]@{
        Node = $Node; AG = $AG; UpdatesInstalled = $res.Found; Rebooted = $rebooted; Result = 'OK'
    })
}

function Invoke-AGFailover {
    param([string]$Target, [string]$AG)
    Write-Log "[$AG] Planned failover to $Target..." 'Yellow'
    Invoke-SqlNonQuery $Target "ALTER AVAILABILITY GROUP [$AG] FAILOVER;"
    Wait-Until -What "[$AG] $Target is PRIMARY and AG is healthy" -TimeoutMinutes $SyncTimeoutMinutes -Condition {
        ((Get-NodeRole $Target $AG) -eq 'PRIMARY') -and (Test-AGHealthy $Target $AG)
    }
    if ($DagName) {
        Wait-Until -What "[$DagName] healthy after $AG failover" -TimeoutMinutes $SyncTimeoutMinutes -Condition { Test-DagHealthy }
    }
}

function Invoke-AGPatch {
    param([hashtable]$Group)
    $ag = $Group.Name
    $primary   = Get-AGPrimary $ag $Group.Nodes
    $secondary = @($Group.Nodes | Where-Object { $_ -ne $primary })[0]

    Write-Log "===== $ag  (primary: $primary, secondary: $secondary) =====" 'Cyan'

    if (-not (Test-AGHealthy $primary $ag)) { throw "$ag is not healthy/SYNCHRONIZED. Nothing patched." }
    if (-not (Test-DagHealthy))            { throw "$DagName is not healthy. Nothing patched." }

    # 1. Secondary first
    Update-Node -Node $secondary -AG $ag -Primary $primary

    # 2. Does the primary need anything?
    Write-Log "[$primary] Checking for updates on the primary..." 'Cyan'
    $scan = Invoke-NodeUpdates $primary 'Scan'
    if ($scan.Found -eq 0 -and -not $scan.RebootRequired) {
        Write-Log "[$primary] Nothing to install and no reboot pending. No failover needed." 'Green'
        $script:Summary.Add([pscustomobject]@{ Node = $primary; AG = $ag; UpdatesInstalled = 0; Rebooted = $false; Result = 'OK' })
        return
    }

    # 3. Planned failover to the patched node, then patch the old primary
    Invoke-AGFailover -Target $secondary -AG $ag
    Update-Node -Node $primary -AG $ag -Primary $secondary

    # 4. Fail back
    if (-not $NoFailBack) {
        Invoke-AGFailover -Target $primary -AG $ag
    }
    else {
        Write-Log "[$ag] -NoFailBack set. Leaving $secondary as primary." 'Yellow'
    }
}

# ---------------------------------------------------------------- main

$exitCode = 0
try {
    $allNodes = @($AvailabilityGroups | ForEach-Object { $_.Nodes })
    if ($allNodes -contains $env:COMPUTERNAME) {
        throw "Run this from a machine that is not one of the nodes (not $env:COMPUTERNAME), because it reboots the nodes."
    }

    # Patch order: DAG secondary side first, global primary side last.
    $ordered = foreach ($g in $AvailabilityGroups) {
        $p = Get-AGPrimary $g.Name $g.Nodes
        [pscustomobject]@{ Group = $g; Primary = $p; DagRole = (Get-DagRole $p $g.Name) }
    }
    $ordered = @($ordered | Sort-Object @{ e = { if ($_.DagRole -eq 'PRIMARY') { 1 } else { 0 } } })
    Write-Log ("Patch order: " + (($ordered | ForEach-Object { "$($_.Group.Name) (DAG $($_.DagRole))" }) -join '  ->  ')) 'Cyan'

    if ($ReportOnly) {
        Write-Log "DRY RUN. Nothing will be installed, failed over or rebooted. Add -Execute to patch." 'Yellow'
        if ($DagName) { Write-Log "$DagName healthy: $(Test-DagHealthy)" }
        foreach ($o in $ordered) {
            $ag = $o.Group.Name
            Write-Log "[$ag] healthy and SYNCHRONIZED: $(Test-AGHealthy $o.Primary $ag)"
            foreach ($n in $o.Group.Nodes) {
                $role = Get-NodeRole $n $ag
                Write-Log "[$n] $role for $ag. Scanning..."
                $scan = Invoke-NodeUpdates $n 'Scan'
                $script:Summary.Add([pscustomobject]@{
                    Node = $n; AG = $ag; Role = $role; UpdatesAvailable = $scan.Found; RebootPending = $scan.RebootRequired
                })
                $scan.Titles | ForEach-Object { Write-Log "[$n]   $_" }
            }
        }
    }
    else {
        foreach ($o in $ordered) { Invoke-AGPatch -Group $o.Group }
        Write-Log "All availability groups patched." 'Green'
    }
}
catch {
    $exitCode = 1
    Write-Log "STOPPED: $($_.Exception.Message)" 'Red'
    Write-Log "Current roles:" 'Red'
    foreach ($g in $AvailabilityGroups) {
        foreach ($n in $g.Nodes) {
            $r = try { Get-NodeRole $n $g.Name } catch { 'UNREACHABLE' }
            Write-Log "   $n  $($g.Name)  $r" 'Red'
        }
    }
}
finally {
    Write-Host "`n===== Summary =====" -ForegroundColor Cyan
    $script:Summary | Format-Table -AutoSize | Out-String | Write-Host

    # Post-run AG status report, if the report script sits alongside this one
    $statusScript = Join-Path $PSScriptRoot 'Get-AGStatusReport.ps1'
    if (Test-Path $statusScript) {
        try { & $statusScript -AvailabilityGroups $AvailabilityGroups -DagName $DagName -SqlPort $SqlPort }
        catch { Write-Log "AG status report failed: $($_.Exception.Message)" 'Red' }
    }

    Stop-Transcript | Out-Null
}
exit $exitCode
