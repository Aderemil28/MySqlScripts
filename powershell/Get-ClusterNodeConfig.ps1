<#
.SYNOPSIS
    Collects Windows failover cluster, AG cluster resource, network and OS/NIC
    settings from the local node into one CSV, so nodes can be compared with
    Compare-ClusterNodeConfig.ps1.

.DESCRIPTION
    Output: <OutputFolder>\<COMPUTERNAME>_config.csv with columns
    Category, Item, Setting, Value. Captures:
      - cluster common properties (heartbeat delay and thresholds, quorum, etc.)
      - cluster networks and their roles/metrics
      - AG and listener resource private properties (LeaseTimeout,
        HealthCheckTimeout, FailureConditionLevel, RegisterAllProvidersIP, HostRecordTTL)
      - OS version, power plan, NIC driver/speed and advanced properties

.PARAMETER OutputFolder
    Folder for the CSV. Created if missing.

.EXAMPLE
    .\Get-ClusterNodeConfig.ps1
    # then copy every <node>_config.csv into one folder and run Compare-ClusterNodeConfig.ps1

.NOTES
    Run elevated on each cluster node. Needs the FailoverClusters module
    (installed with the Failover Clustering feature). Read-only.
#>
[CmdletBinding()]
param(
    [string]$OutputFolder = 'C:\Temp'
)

if (-not (Test-Path $OutputFolder)) { New-Item -ItemType Directory -Path $OutputFolder | Out-Null }
$out  = Join-Path $OutputFolder "$($env:COMPUTERNAME)_config.csv"
$rows = New-Object System.Collections.Generic.List[object]

function Add-Row([string]$Category, [string]$Item, [string]$Setting, $Value) {
    $rows.Add([pscustomobject]@{ Category = $Category; Item = $Item; Setting = $Setting; Value = "$Value" })
}

# --- Cluster ---
try {
    Import-Module FailoverClusters -ErrorAction Stop
    $cluster = Get-Cluster
    $clusterProps = 'SameSubnetDelay','SameSubnetThreshold','CrossSubnetDelay','CrossSubnetThreshold',
                    'RouteHistoryLength','QuarantineThreshold','QuarantineDuration','ResiliencyLevel',
                    'ResiliencyDefaultPeriod','DynamicQuorum','WitnessDynamicWeight','PlumbAllCrossSubnetRoutes',
                    'ClusterLogLevel','ClusterLogSize'
    foreach ($p in $clusterProps) {
        if ($cluster.PSObject.Properties[$p]) { Add-Row 'Cluster' $cluster.Name $p $cluster.$p }
    }
    $q = Get-ClusterQuorum
    Add-Row 'Cluster' $cluster.Name 'QuorumType'     $q.QuorumType
    Add-Row 'Cluster' $cluster.Name 'QuorumResource' $q.QuorumResource

    foreach ($n in Get-ClusterNetwork) {
        Add-Row 'ClusterNetwork' $n.Name 'Role'    $n.Role
        Add-Row 'ClusterNetwork' $n.Name 'Metric'  $n.Metric
        Add-Row 'ClusterNetwork' $n.Name 'Address' "$($n.Address)/$($n.AddressMask)"
        Add-Row 'ClusterNetwork' $n.Name 'State'   $n.State
    }

    foreach ($node in Get-ClusterNode) {
        Add-Row 'ClusterNode' $node.Name 'State'   $node.State
        Add-Row 'ClusterNode' $node.Name 'NodeWeight' $node.NodeWeight
    }

    $agResources = Get-ClusterResource | Where-Object { $_.ResourceType -in 'SQL Server Availability Group', 'Network Name', 'IP Address' }
    foreach ($r in $agResources) {
        Add-Row 'ClusterResource' $r.Name 'ResourceType' $r.ResourceType
        Add-Row 'ClusterResource' $r.Name 'OwnerGroup'   $r.OwnerGroup
        foreach ($pp in ($r | Get-ClusterParameter -ErrorAction SilentlyContinue)) {
            if ($pp.Name -in 'LeaseTimeout','HealthCheckTimeout','FailureConditionLevel',
                             'RegisterAllProvidersIP','HostRecordTTL','PublishPTRRecords','DnsName','Address','SubnetMask','EnableDhcp') {
                Add-Row 'ClusterResource' $r.Name $pp.Name $pp.Value
            }
        }
        foreach ($cp in 'RestartAction','RestartThreshold','RestartPeriod','PendingTimeout','IsAlivePollInterval','LooksAlivePollInterval') {
            if ($r.PSObject.Properties[$cp]) { Add-Row 'ClusterResource' $r.Name $cp $r.$cp }
        }
    }
} catch {
    Add-Row 'Cluster' $env:COMPUTERNAME 'Error' $_.Exception.Message
}

# --- OS ---
$os = Get-CimInstance Win32_OperatingSystem
Add-Row 'OS' $env:COMPUTERNAME 'Caption'     $os.Caption
Add-Row 'OS' $env:COMPUTERNAME 'Version'     $os.Version
Add-Row 'OS' $env:COMPUTERNAME 'LastBootUp'  $os.LastBootUpTime
$plan = (powercfg /getactivescheme) -replace '.*\((.*)\).*', '$1'
Add-Row 'OS' $env:COMPUTERNAME 'PowerPlan' $plan

# --- NICs ---
foreach ($nic in Get-NetAdapter -Physical -ErrorAction SilentlyContinue) {
    Add-Row 'NIC' $nic.Name 'InterfaceDescription' $nic.InterfaceDescription
    Add-Row 'NIC' $nic.Name 'Status'               $nic.Status
    Add-Row 'NIC' $nic.Name 'LinkSpeed'            $nic.LinkSpeed
    Add-Row 'NIC' $nic.Name 'DriverVersion'        $nic.DriverVersion
    Add-Row 'NIC' $nic.Name 'MtuSize'              $nic.MtuSize
    foreach ($ap in (Get-NetAdapterAdvancedProperty -Name $nic.Name -ErrorAction SilentlyContinue)) {
        Add-Row 'NIC' $nic.Name $ap.DisplayName $ap.DisplayValue
    }
    $rss = Get-NetAdapterRss -Name $nic.Name -ErrorAction SilentlyContinue
    if ($rss) { Add-Row 'NIC' $nic.Name 'RSS Enabled' $rss.Enabled }
}

$rows | Export-Csv -Path $out -NoTypeInformation
Write-Host "Saved $($rows.Count) settings to $out"
