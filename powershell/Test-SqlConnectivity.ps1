<#
.SYNOPSIS
    Step-by-step connectivity check from the machine where an application runs to
    a SQL Server instance: DNS, TCP port, and an actual SQL login.

.DESCRIPTION
    Use it for "connection refused", "server not found" or login timeout errors.
      1. Resolves the host name and shows every IP it returns
      2. Tests the TCP port on each IP (not just the first), which catches the
         common multi-instance problem where each named instance listens on its
         own IP and the app resolves to the wrong one
      3. Optionally opens a real connection with Integrated Security and
         returns @@SERVERNAME, the auth scheme and encryption

    Run it from the same place the app runs (app server, container host, jump
    box). A test from your own desktop proves nothing about the app's path.

.PARAMETER HostName
    Name exactly as the app uses it (short name, FQDN or alias). Try both if unsure.

.PARAMETER Port
    TCP port the instance listens on (static port recommended for named instances).

.PARAMETER Instance
    Optional instance name, only used for the SQL login test (HOST\INSTANCE).

.PARAMETER TestLogin
    Also try a SQL connection using the current Windows identity.

.EXAMPLE
    .\Test-SqlConnectivity.ps1 -HostName sqlhost01.corp.example -Port 1433 -TestLogin
    .\Test-SqlConnectivity.ps1 -HostName sqlhost01 -Port 50101 -Instance SALES -TestLogin

.NOTES
    Read-only. On Linux hosts use: nslookup <host>, nc -vz <host> <port>.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$HostName,
    [int]$Port = 1433,
    [string]$Instance,
    [switch]$TestLogin
)

Write-Host "1. DNS lookup for $HostName" -ForegroundColor Cyan
try {
    $ips = [System.Net.Dns]::GetHostAddresses($HostName) | Where-Object { $_.AddressFamily -eq 'InterNetwork' }
    $ips | ForEach-Object { Write-Host "   $($_.IPAddressToString)" }
    try {
        $fqdn = [System.Net.Dns]::GetHostEntry($HostName).HostName
        Write-Host "   Canonical name: $fqdn"
    } catch { Write-Verbose 'Reverse lookup not available' }
} catch {
    Write-Host "   FAILED: $($_.Exception.Message)" -ForegroundColor Red
    return
}

Write-Host "2. TCP port $Port on each address" -ForegroundColor Cyan
foreach ($ip in $ips) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($ip, $Port, $null, $null)
        $ok = $async.AsyncWaitHandle.WaitOne(3000, $false) -and $client.Connected
        if ($ok) { Write-Host "   $($ip.IPAddressToString):$Port  OPEN" -ForegroundColor Green }
        else     { Write-Host "   $($ip.IPAddressToString):$Port  CLOSED / FILTERED / REFUSED" -ForegroundColor Red }
    } catch {
        Write-Host "   $($ip.IPAddressToString):$Port  ERROR $($_.Exception.InnerException.Message)" -ForegroundColor Red
    } finally {
        $client.Close()
    }
}

if ($TestLogin) {
    Write-Host '3. SQL login test (Windows authentication)' -ForegroundColor Cyan
    $server = if ($Instance) { "$HostName\$Instance" } else { "$HostName,$Port" }
    $cs = "Server=$server;Database=master;Integrated Security=SSPI;Connect Timeout=10;TrustServerCertificate=True;Application Name=Test-SqlConnectivity"
    $conn = New-Object System.Data.SqlClient.SqlConnection $cs
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = 'SELECT @@SERVERNAME AS server_name, auth_scheme, encrypt_option, local_net_address, local_tcp_port FROM sys.dm_exec_connections WHERE session_id = @@SPID;'
        $r = $cmd.ExecuteReader()
        while ($r.Read()) {
            Write-Host ("   Connected to {0}  auth={1}  encrypted={2}  ip={3}  port={4}" -f $r[0], $r[1], $r[2], $r[3], $r[4]) -ForegroundColor Green
        }
        $r.Close()
    } catch {
        Write-Host "   FAILED: $($_.Exception.Message)" -ForegroundColor Red
    } finally {
        $conn.Close()
    }
}
