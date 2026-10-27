<#
.SYNOPSIS
    Lists every SQL Server Database Engine instance on one or more servers with
    its edition, version and patch level, read from the registry.

.DESCRIPTION
    Works without connecting to SQL Server, so it also finds stopped
    instances. Useful for licensing reviews and patching inventories.
    Reads HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL to
    map each instance name to its registry key, then reads the key's Setup
    values (Edition, Version, PatchLevel).

.PARAMETER ComputerName
    Servers to check. Defaults to the local server. Remote servers are read
    with Invoke-Command, so they need PowerShell remoting (WinRM).

.EXAMPLE
    .\Get-SqlServerEdition.ps1
    .\Get-SqlServerEdition.ps1 -ComputerName SQL01, SQL02 | Format-Table -AutoSize
    Get-Content .\servers.txt | .\Get-SqlServerEdition.ps1 | Export-Csv .\sql_editions.csv -NoTypeInformation

.NOTES
    Read-only. Run elevated.
    Fixes vs the original notes: the original matched registry keys named
    MSSQL15 to MSSQL19 only, so it missed SQL Server 2017 and older
    (MSSQL14 and below) and anything else in the folder that happened to
    match. It now uses the Instance Names list, which covers every version.
#>
[CmdletBinding()]
param(
    [Parameter(ValueFromPipeline)]
    [string[]]$ComputerName = $env:COMPUTERNAME
)

begin {
    $scriptBlock = {
        $root  = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server'
        $names = Get-ItemProperty "$root\Instance Names\SQL" -ErrorAction SilentlyContinue
        if (-not $names) {
            [pscustomobject]@{ Server = $env:COMPUTERNAME; Instance = ''; Edition = ''; Version = ''; PatchLevel = ''; Note = 'No Database Engine instance found' }
            return
        }
        foreach ($p in $names.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' }) {
            $setup = Get-ItemProperty "$root\$($p.Value)\Setup" -ErrorAction SilentlyContinue
            [pscustomobject]@{
                Server     = $env:COMPUTERNAME
                Instance   = $p.Name                 # MSSQLSERVER = default instance
                Edition    = $setup.Edition
                Version    = $setup.Version
                PatchLevel = $setup.PatchLevel
                Note       = $p.Value                # registry key, for example MSSQL16.MSSQLSERVER
            }
        }
    }
}

process {
    foreach ($c in $ComputerName) {
        if ($c -eq $env:COMPUTERNAME -or $c -eq 'localhost' -or $c -eq '.') {
            & $scriptBlock
        } else {
            try {
                Invoke-Command -ComputerName $c -ScriptBlock $scriptBlock -ErrorAction Stop |
                    Select-Object Server, Instance, Edition, Version, PatchLevel, Note
            } catch {
                [pscustomobject]@{ Server = $c; Instance = ''; Edition = ''; Version = ''; PatchLevel = ''; Note = "Unreachable: $($_.Exception.Message)" }
            }
        }
    }
}
