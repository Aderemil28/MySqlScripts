<#
.SYNOPSIS
    AG-aware SQL Server patching (CU or GDR): secondary first, planned failover, then the old primary.
    Works with plain availability groups and with two AGs linked by a distributed AG.

.DESCRIPTION
    Same safe pattern as Invoke-AGPatching.ps1, but installs a SQL Server update file instead of
    Windows updates.

      1. With a distributed AG, the AG on the DAG secondary side is patched first and the AG on the
         global primary side last. The order is worked out at run time from the live roles.
      2. The DAG primary side is not touched until every node on the DAG secondary side is on the
         target build. A newer build must never become primary while older replicas still receive from it.
      3. Within each AG:
           a. Pre-check: AG and DAG healthy. If not, stop.
           b. Patch the SECONDARY if it is below the target build. Reboot only if setup asks for it.
              Confirm the new build, wait for the AG to resync.
           c. If the PRIMARY is already on the target build, stop there for this AG (no failover).
           d. Planned failover to the patched node, patch the old primary, confirm build, resync.
           e. Fail back to the original primary (unless -NoFailBack).
      4. Nodes already on (or above) the target build are skipped.
      5. Any failure stops the whole run.
      6. Ends with a before/after build table and, if Get-AGStatusReport.ps1 is in the same folder,
         the AG status report.

    Setup runs silently on each node:
      /quiet /IAcceptSQLServerLicenseTerms /Action=Patch /AllInstances

.PARAMETER InstallerPath
    Full path ON THE MACHINE RUNNING THE SCRIPT to the SQL Server update .exe, downloaded from the
    Microsoft Update Catalog. It is copied to C:\Temp\SQLPatch on each node.

.PARAMETER TargetBuild
    The build the update installs (for example 16.0.4305.5). Used to skip nodes that are already
    patched and to confirm each install worked.

.PARAMETER AvailabilityGroups
    One hashtable per AG with its name and nodes, for example:
      @{ Name = 'AG1'; Nodes = 'SQLNODE01','SQLNODE02' }, @{ Name = 'AG2'; Nodes = 'SQLNODE03','SQLNODE04' }

.PARAMETER DagName
    Name of the distributed AG linking the AGs above. Leave empty if there is none.

.PARAMETER SqlPort
    TCP port the instances listen on. Connections go straight to tcp:<node>,<port>.

.PARAMETER Execute
    Without it the script only reports each node's role, current build and whether it would be patched.

.PARAMETER NoFailBack
    Leave each AG on whichever node it ends up on instead of failing back to the original primary.

.EXAMPLE
    # Dry run (default)
    $ags = @{ Name = 'AG1'; Nodes = 'SQLNODE01','SQLNODE02' }, @{ Name = 'AG2'; Nodes = 'SQLNODE03','SQLNODE04' }
    .\Invoke-SQLPatching.ps1 -AvailabilityGroups $ags -DagName 'DAG1' `
        -InstallerPath 'C:\Patches\SQL\SQLServer2022-KB5126934-x64.exe' -TargetBuild 16.0.4305.5

.EXAMPLE
    # Real run
    .\Invoke-SQLPatching.ps1 -AvailabilityGroups $ags -DagName 'DAG1' `
        -InstallerPath 'C:\Patches\SQL\SQLServer2022-KB5126934-x64.exe' -TargetBuild 16.0.4305.5 -Execute

.NOTES
    RUN IT FROM A MACHINE THAT IS NOT ONE OF THE NODES. The script refuses to run on a node.
    The account needs local admin on every node and sysadmin on every instance.
    PowerShell remoting (WinRM) must be enabled on the nodes. Two-node AGs only.
    If setup fails, the error points to Summary.txt under
    C:\Program Files\Microsoft SQL Server\<version>\Setup Bootstrap\Log on that node.
    Windows PowerShell 5.1.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$InstallerPath,
    [Parameter(Mandatory)] [version]$TargetBuild,
    [Parameter(Mandatory)] [hashtable[]]$AvailabilityGroups,
    [string]$DagName,
    [int]$SqlPort = 1433,
    [switch]$Execute,
    [switch]$NoFailBack,
    [int]$SyncTimeoutMinutes = 30,
    [string]$LogFolder = 'C:\Scripts\Logs_SQL'
)

$ErrorActionPreference = 'Stop'
$ReportOnly = -not $Execute
New-Item -Path $LogFolder -ItemType Directory -Force | Out-Null
$logFile = Join-Path $LogFolder ("SQL-Patching_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmm'))
Start-Transcript -Path $logFile | Out-Null

$script:Summary      = New-Object System.Collections.Generic.List[object]
$script:BuildsBefore = @{}
$remoteDir = 'C:\Temp\SQLPatch'

# ---------------------------------------------------------------- helpers

function Write-Log {
    param([string]$Message, [string]$Color = 'Gray')
    Write-Host ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -ForegroundColor $Color
}

function Invoke-Sql {
    param([string]$Server, [string]$Query)
    $conn = New-Object System.Data.SqlClient.SqlConnection "Server=tcp:$Server,$SqlPort;Database=master;Integrated Security=True;Connect Timeout=15;Application Name=SQLPatching"
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
    $conn = New-Object System.Data.SqlClient.SqlConnection "Server=tcp:$Server,$SqlPort;Database=master;Integrated Security=True;Connect Timeout=15;Application Name=SQLPatching"
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

function Get-Build {
    param([string]$Node)
    [version](@(Invoke-Sql $Node "SELECT CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(50)) AS v;")[0].v)
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

# ---------------------------------------------------------------- SQL update on a node

function Install-SqlUpdate {
    # Patch one node that is currently a SECONDARY, reboot if needed, confirm build, wait for resync.
    param([string]$Node, [string]$AG, [string]$Primary)

    $role = Get-NodeRole $Node $AG
    if ($role -ne 'SECONDARY') { throw "$Node is $role for $AG, not SECONDARY. Refusing to patch it." }

    $before = Get-Build $Node
    if ($before -ge $TargetBuild) {
        Write-Log "[$Node] Already on $before (target $TargetBuild). Skipping." 'Green'
        $script:Summary.Add([pscustomobject]@{ Node = $Node; AG = $AG; Before = $before; After = $before; Rebooted = $false; Result = 'Already patched' })
        return
    }

    Write-Log "[$Node] Copying update to $remoteDir..." 'Cyan'
    $fileName = Split-Path $InstallerPath -Leaf
    $session = New-PSSession -ComputerName $Node
    try {
        Invoke-Command -Session $session -ArgumentList $remoteDir -ScriptBlock { param($d) New-Item -Path $d -ItemType Directory -Force | Out-Null }
        Copy-Item -Path $InstallerPath -Destination (Join-Path $remoteDir $fileName) -ToSession $session -Force

        Write-Log "[$Node] Installing $fileName (build $before -> $TargetBuild). SQL Server will restart during this..." 'Yellow'
        $exitCode = Invoke-Command -Session $session -ArgumentList (Join-Path $remoteDir $fileName) -ScriptBlock {
            param($exe)
            $p = Start-Process -FilePath $exe -ArgumentList '/quiet', '/IAcceptSQLServerLicenseTerms', '/Action=Patch', '/AllInstances' -Wait -PassThru
            $p.ExitCode
        }
    }
    finally { Remove-PSSession $session }

    Write-Log "[$Node] Setup exit code: $exitCode"
    if ($exitCode -notin 0, 3010) {
        throw "SQL setup on $Node failed with exit code $exitCode. Check Summary.txt under C:\Program Files\Microsoft SQL Server\<version>\Setup Bootstrap\Log on $Node."
    }

    $rebooted = $false
    $pending = Invoke-Command -ComputerName $Node -ScriptBlock {
        (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
        (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
    }
    if ($exitCode -eq 3010 -or $pending) {
        Write-Log "[$Node] Reboot required. Rebooting..." 'Yellow'
        Restart-Computer -ComputerName $Node -Force -Wait -For PowerShell -Timeout 3600 -Delay 15
        $rebooted = $true
    }

    Wait-Until -What "[$Node] SQL Server back online" -TimeoutMinutes $SyncTimeoutMinutes -Condition {
        @(Invoke-Sql $Node 'SELECT 1 AS Up;').Count -eq 1
    }

    $after = Get-Build $Node
    if ($after -lt $TargetBuild) { throw "$Node is on $after after setup, expected $TargetBuild. Stopping." }
    Write-Log "[$Node] Now on $after." 'Green'

    Wait-Until -What "[$AG] healthy and SYNCHRONIZED after patching $Node" -TimeoutMinutes $SyncTimeoutMinutes -Condition {
        Test-AGHealthy $Primary $AG
    }

    $script:Summary.Add([pscustomobject]@{ Node = $Node; AG = $AG; Before = $before; After = $after; Rebooted = $rebooted; Result = 'Patched' })
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
    Install-SqlUpdate -Node $secondary -AG $ag -Primary $primary

    # 2. Primary already done?
    $pBuild = Get-Build $primary
    if ($pBuild -ge $TargetBuild) {
        Write-Log "[$primary] Primary already on $pBuild. No failover needed." 'Green'
        $script:Summary.Add([pscustomobject]@{ Node = $primary; AG = $ag; Before = $pBuild; After = $pBuild; Rebooted = $false; Result = 'Already patched' })
        return
    }

    # 3. Failover to the patched node, patch the old primary
    Invoke-AGFailover -Target $secondary -AG $ag
    Install-SqlUpdate -Node $primary -AG $ag -Primary $secondary

    # 4. Fail back
    if (-not $NoFailBack) { Invoke-AGFailover -Target $primary -AG $ag }
    else { Write-Log "[$ag] -NoFailBack set. Leaving $secondary as primary." 'Yellow' }
}

# ---------------------------------------------------------------- main

$exitCode = 0
try {
    $allNodes = @($AvailabilityGroups | ForEach-Object { $_.Nodes })
    if ($allNodes -contains $env:COMPUTERNAME) {
        throw "Run this from a machine that is not one of the nodes (not $env:COMPUTERNAME), because it restarts SQL Server on the nodes."
    }
    if (-not (Test-Path $InstallerPath)) { throw "Update file not found: $InstallerPath" }

    foreach ($n in $allNodes) { $script:BuildsBefore[$n] = Get-Build $n }
    Write-Log "Target build: $TargetBuild   Update file: $InstallerPath" 'Cyan'
    foreach ($n in $allNodes) { Write-Log ("   {0}  {1}" -f $n, $script:BuildsBefore[$n]) }

    # Patch order: DAG secondary side first, global primary side last
    $ordered = foreach ($g in $AvailabilityGroups) {
        $p = Get-AGPrimary $g.Name $g.Nodes
        [pscustomobject]@{ Group = $g; Primary = $p; DagRole = (Get-DagRole $p $g.Name) }
    }
    $ordered = @($ordered | Sort-Object @{ e = { if ($_.DagRole -eq 'PRIMARY') { 1 } else { 0 } } })
    Write-Log ("Patch order: " + (($ordered | ForEach-Object { "$($_.Group.Name) (DAG $($_.DagRole))" }) -join '  ->  ')) 'Cyan'

    if ($ReportOnly) {
        Write-Log "DRY RUN. Nothing will be installed, failed over or restarted. Add -Execute to patch." 'Yellow'
        if ($DagName) { Write-Log "$DagName healthy: $(Test-DagHealthy)" }
        foreach ($o in $ordered) {
            $ag = $o.Group.Name
            Write-Log "[$ag] healthy and SYNCHRONIZED: $(Test-AGHealthy $o.Primary $ag)"
            foreach ($n in $o.Group.Nodes) {
                $b = $script:BuildsBefore[$n]
                $script:Summary.Add([pscustomobject]@{
                    Node = $n; AG = $ag; Role = (Get-NodeRole $n $ag); CurrentBuild = $b; TargetBuild = $TargetBuild
                    Action = if ($b -ge $TargetBuild) { 'Skip (already patched)' } else { 'Will patch' }
                })
            }
        }
    }
    else {
        foreach ($o in $ordered) {
            if ($DagName -and $o.DagRole -eq 'PRIMARY') {
                # Safety: the DAG secondary side must be fully patched before the DAG primary side fails over
                $dagSecondaryNodes = @($ordered | Where-Object { $_.DagRole -ne 'PRIMARY' } | ForEach-Object { $_.Group.Nodes })
                $behind = @($dagSecondaryNodes | Where-Object { (Get-Build $_) -lt $TargetBuild })
                if ($behind.Count) {
                    throw "DAG secondary side not fully patched ($($behind -join ', ')). Will not patch $($o.Group.Name)."
                }
            }
            Invoke-AGPatch -Group $o.Group
        }
        Write-Log "All availability groups on $TargetBuild." 'Green'
    }
}
catch {
    $exitCode = 1
    Write-Log "STOPPED: $($_.Exception.Message)" 'Red'
    Write-Log "Current roles and builds:" 'Red'
    foreach ($g in $AvailabilityGroups) {
        foreach ($n in $g.Nodes) {
            $r = try { Get-NodeRole $n $g.Name } catch { 'UNREACHABLE' }
            $b = try { Get-Build $n } catch { '?' }
            Write-Log "   $n  $($g.Name)  $r  $b" 'Red'
        }
    }
}
finally {
    Write-Host "`n===== Summary =====" -ForegroundColor Cyan
    $script:Summary | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

    $statusScript = Join-Path $PSScriptRoot 'Get-AGStatusReport.ps1'
    if (Test-Path $statusScript) {
        try { & $statusScript -AvailabilityGroups $AvailabilityGroups -DagName $DagName -SqlPort $SqlPort }
        catch { Write-Log "AG status report failed: $($_.Exception.Message)" 'Red' }
    }
    Stop-Transcript | Out-Null
}
exit $exitCode
