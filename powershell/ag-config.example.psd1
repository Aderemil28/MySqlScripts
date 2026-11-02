# Copy to ag-config.psd1 in the same folder as the scripts and fill in your own values.
# Get-AGStatusReport.ps1 reads it when run with no parameters, so the patching scripts
# (and a scheduled task) can call the report without passing the AG list every time.
# ag-config.psd1 is in .gitignore so real server names never get committed.
@{
    # List the PREFERRED PRIMARY FIRST for each AG. The report flags a failover when
    # the current primary is not the first node listed.
    AvailabilityGroups = @(
        @{ Name = 'AG1'; Nodes = @('SQLNODE01', 'SQLNODE02') }
        @{ Name = 'AG2'; Nodes = @('SQLNODE03', 'SQLNODE04') }
    )

    # Distributed AG linking the AGs above. Use '' if there is none.
    DagName = 'DAG1'

    # TCP port every instance listens on.
    SqlPort = 1433
}
