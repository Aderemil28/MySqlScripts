<#
.SYNOPSIS
    Lists the software installed on one or more servers (name, version,
    publisher, install date), read from the registry, and optionally saves it
    to CSV.

.DESCRIPTION
    Reads the 64-bit and 32-bit Uninstall keys, the same list shown in
    Programs and Features. Useful before and after patching or an upgrade,
    for audit evidence, or to compare two cluster nodes.
    Deliberately does not use Win32_Product: querying that class makes
    Windows Installer re-check (and sometimes repair) every MSI package.

.PARAMETER ComputerName
    Servers to check. Defaults to the local server. Remote servers are read
    with Invoke-Command, so they need PowerShell remoting (WinRM).

.PARAMETER Name
    Optional wildcard filter on the display name, for example '*SQL*' or
    '*Visual C++*'.

.PARAMETER OutputFolder
    Optional folder. When set, one CSV per server is written there as
    InstalledSoftware_<server>.csv.

.EXAMPLE
    .\Get-InstalledSoftware.ps1
    .\Get-InstalledSoftware.ps1 -Name '*SQL*' | Format-Table -AutoSize
    .\Get-InstalledSoftware.ps1 -ComputerName SQL01, SQL02 -OutputFolder C:\Temp

.NOTES
    Read-only. Run elevated for the full list.
    Fixes vs the original notes: the original was a one-liner that only ran
    locally and always wrote to C:\Temp (which may not exist). Added remote
    servers, a name filter, an optional output folder that is created if
    missing, an Architecture column, de-duplication of entries listed under
    both keys, and InstallDate as a real date where the registry has one.
#>
[CmdletBinding()]
param(
    [Parameter(ValueFromPipeline)]
    [string[]]$ComputerName = $env:COMPUTERNAME,
    [string]$Name = '*',
    [string]$OutputFolder
)

begin {
    $scriptBlock = {
        param($NameFilter)
        $keys = @(
            @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*';             Arch = '64-bit' },
            @{ Path = 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'; Arch = '32-bit' }
        )
        foreach ($k in $keys) {
            Get-ItemProperty -Path $k.Path -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -and $_.DisplayName -like $NameFilter -and -not $_.SystemComponent } |
                ForEach-Object {
                    $date = $null
                    if ($_.InstallDate -match '^\d{8}$') {
                        $date = [datetime]::ParseExact($_.InstallDate, 'yyyyMMdd', $null)
                    }
                    [pscustomobject]@{
                        Server         = $env:COMPUTERNAME
                        DisplayName    = $_.DisplayName
                        DisplayVersion = $_.DisplayVersion
                        Publisher      = $_.Publisher
                        InstallDate    = $date
                        Architecture   = $k.Arch
                    }
                }
        }
    }
    if ($OutputFolder -and -not (Test-Path $OutputFolder)) {
        New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
    }
}

process {
    foreach ($c in $ComputerName) {
        try {
            if ($c -eq $env:COMPUTERNAME -or $c -eq 'localhost' -or $c -eq '.') {
                $rows = & $scriptBlock $Name
            } else {
                $rows = Invoke-Command -ComputerName $c -ScriptBlock $scriptBlock -ArgumentList $Name -ErrorAction Stop |
                    Select-Object Server, DisplayName, DisplayVersion, Publisher, InstallDate, Architecture
            }
            $rows = $rows | Sort-Object DisplayName, DisplayVersion -Unique
            if ($OutputFolder) {
                $file = Join-Path $OutputFolder ("InstalledSoftware_{0}.csv" -f $c)
                $rows | Export-Csv -Path $file -NoTypeInformation
                Write-Verbose "Saved $($rows.Count) rows to $file"
            }
            $rows
        } catch {
            Write-Warning "$c : $($_.Exception.Message)"
        }
    }
}
