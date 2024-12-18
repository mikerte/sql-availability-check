<#
.SYNOPSIS
    Automates SQL Server instance discovery, availability checks, and database health monitoring.

.DESCRIPTION
    This script checks the availability and health of SQL Server instances, Always On Availability Groups (AG), 
    and standalone databases. It discovers instances by enumerating services whose Name starts with "MSSQL" 
    and DisplayName starts with "SQL Server". For each discovered instance, it performs:
    
    - SQL Server availability checks and logs the version.
    - Always On AG checks, including replica roles, synchronization health, and AG database statuses.
    - Standalone database checks for databases not part of any AG.

    The script generates a comprehensive log file, providing detailed results and summaries for review.

.PARAMETER Server
    The hostname or IP address of the target server to check SQL Server instances.

.PARAMETER LogDir
    The directory where the log file will be created. If not specified, defaults to "C:\Logs".

.EXAMPLE
    # Check all SQL Server instances on the target server and log results
    .\SQL_Server_Check.ps1 -Server "MyServer" -LogDir "C:\SQLLogs"

.EXAMPLE
    # Run the script with a default log directory
    .\SQL_Server_Check.ps1 -Server "MyServer"

.EXAMPLE
    # Check SQL Server instances on a server and log results to a custom directory
    .\SQL_Server_Check.ps1 -Server "MyServer" -LogDir "D:\CustomLogs"

.NOTES
    - The script uses PowerShell and T-SQL queries to interact with SQL Server.
    - It dynamically discovers SQL Server instances by identifying relevant services.
    - The script is modular and can be extended to include additional health checks.

    Requirements:
    - PowerShell 5.1 or higher.
    - SQL Server 2022 or later for Always On Availability Group (AG) queries.
    - User account must have appropriate permissions to access SQL Server instances and views:
      - sys.databases
      - sys.availability_groups
      - sys.availability_replicas
      - sys.dm_hadr_availability_replica_states
      - sys.availability_databases_cluster
#>

# Parameters
param(
    [string]$Server,          # Server assigned dynamically from UAC
    [string]$LogDir = "C:\Logs"  # Directory for log files
)

# Initialize log file
$logFile = Join-Path $LogDir "SQL_Check_Results_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

# Declare global summary variable
$global:summary = @()

# Function to write logs
Function Write-Log {
    param (
        [string]$Message,
        [string]$Type = "INFO" # INFO, WARNING, ERROR, SEPARATOR
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    
    if ($Type -eq "SEPARATOR") {
        Add-Content $logFile "================================================================="
        Add-Content $logFile $Message
        Add-Content $logFile "================================================================="
    } else {
        Add-Content $logFile "$timestamp [$Type] $Message"
    }
}

# Function to retrieve SQL instances dynamically using Get-Service
Function Get-SqlInstances {
    param (
        [string]$Server
    )
    try {
        Write-Log "Retrieving SQL instances on ${Server}..."
        $services = Get-Service -ComputerName $Server |
                    Where-Object {
                        $_.Name -like "MSSQL*" -and $_.DisplayName -like "SQL Server*"
                    }

        if ($services.Count -gt 0) {
            $instances = $services.Name | ForEach-Object {
                if ($_ -eq "MSSQLSERVER") { $_ } else { $_ -replace "^MSSQL\$", "" }
            }
            Write-Log "Found instances on ${Server}: $($instances -join ', ')"
            return $instances
        } else {
            Write-Log "No SQL instances found on ${Server}. Defaulting to MSSQLSERVER." "WARNING"
            return @("MSSQLSERVER")  # Default to MSSQLSERVER if none are found
        }
    } catch {
        Write-Log "ERROR: Unable to retrieve instances for ${Server} - $($_.Exception.Message)" "ERROR"
        return @("MSSQLSERVER")  # Default to MSSQLSERVER on error
    }
}

# Function to execute SQL queries
Function Invoke-SqlQuery {
    param (
        [string]$Server,
        [string]$Instance,
        [string]$Query
    )
    try {
        $serverInstance = if ($Instance -eq "MSSQLSERVER") { $Server } else { "$Server\$Instance" }

        $connection = New-Object System.Data.SqlClient.SqlConnection
        $connection.ConnectionString = "Server=$serverInstance;Database=master;Integrated Security=True;"
        $connection.Open()

        $command = $connection.CreateCommand()
        $command.CommandText = $Query

        $dataTable = New-Object System.Data.DataTable
        $dataAdapter = New-Object System.Data.SqlClient.SqlDataAdapter $command
        $dataAdapter.Fill($dataTable) | Out-Null

        $connection.Close()
        return $dataTable
    } catch {
        Write-Log "ERROR on ${Server}\${Instance}: $($_.Exception.Message)" "ERROR"
        return $null
    }
}

# Function to check database synchronization status for AGs
Function Check-AgDatabases {
    param (
        [string]$Server,
        [string]$Instance
    )

    Write-Log "${Server}\${Instance}: Checking AG database synchronization status..."

    # Corrected query for AG database synchronization status
    $agDbStatusQuery = @"
SELECT ag.name AS AGName,
       adc.database_name AS DatabaseName,
       drs.synchronization_state_desc AS SyncState,
       drs.synchronization_health_desc AS SyncHealth
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_databases_cluster adc
  ON drs.group_database_id = adc.group_database_id
JOIN sys.availability_groups ag
  ON adc.group_id = ag.group_id;
"@

    $agDbResults = Invoke-SqlQuery -Server $Server -Instance $Instance -Query $agDbStatusQuery

    if ($agDbResults -ne $null -and $agDbResults.Rows.Count -gt 0) {
        foreach ($row in $agDbResults) {
            Write-Log "${Server}\${Instance}: AG: $($row.AGName), Database: $($row.DatabaseName), Sync State: $($row.SyncState), Health: $($row.SyncHealth)"
        }
    } else {
        Write-Log "${Server}\${Instance}: No AG databases found or unable to query AG database statuses." "WARNING"
    }
}

# Function to check standalone database status
Function Check-StandaloneDatabases {
    param (
        [string]$Server,
        [string]$Instance
    )

    Write-Log "${Server}\${Instance}: Checking standalone databases..."

    # Query to find databases not part of any AG
    $nonAgDbStatusQuery = @"
SELECT d.name AS DatabaseName,
       d.state_desc AS State,
       d.recovery_model_desc AS RecoveryModel
FROM sys.databases d
LEFT JOIN sys.availability_databases_cluster adc
  ON d.name = adc.database_name
WHERE adc.database_name IS NULL
"@

    $dbResults = Invoke-SqlQuery -Server $Server -Instance $Instance -Query $nonAgDbStatusQuery

    if ($dbResults -ne $null -and $dbResults.Rows.Count -gt 0) {
        foreach ($row in $dbResults) {
            Write-Log "${Server}\${Instance}: Standalone Database: $($row.DatabaseName), State: $($row.State), Recovery Model: $($row.RecoveryModel)"
        }
    } else {
        Write-Log "${Server}\${Instance}: No standalone databases found." "INFO"
    }
}

# Function to check SQL Server and Always On status
Function Check-SqlInstance {
    param (
        [string]$Server,
        [string]$Instance
    )

    Write-Log "Starting checks for ${Server}\${Instance}"

    # Step 1: Check SQL Server Availability
    try {
        $query = "SELECT SERVERPROPERTY('ProductVersion') AS SQLVersion;"
        $result = Invoke-SqlQuery -Server $Server -Instance $Instance -Query $query
        if ($result) {
            Write-Log "${Server}\${Instance}: SQL Server Available - Version: $($result.SQLVersion)"
            $global:summary += [PSCustomObject]@{ Server = $Server; Instance = $Instance; Status = "Available"; Version = $($result.SQLVersion) }
        } else {
            Write-Log "${Server}\${Instance}: SQL Server Unavailable" "WARNING"
            $global:summary += [PSCustomObject]@{ Server = $Server; Instance = $Instance; Status = "Unavailable"; Version = "N/A" }
            return
        }
    } catch {
        Write-Log "ERROR: Unable to check SQL Server availability for ${Server}\${Instance} - $($_.Exception.Message)" "ERROR"
        $global:summary += [PSCustomObject]@{ Server = $Server; Instance = $Instance; Status = "Error"; Version = "N/A" }
        return
    }

    # Step 2: Check Always On Availability Groups (AG) Status
    try {
        $isAlwaysOnEnabledQuery = "SELECT SERVERPROPERTY('IsHadrEnabled') AS IsAlwaysOnEnabled;"
        $isAlwaysOnEnabled = Invoke-SqlQuery -Server $Server -Instance $Instance -Query $isAlwaysOnEnabledQuery

        if ($isAlwaysOnEnabled.IsAlwaysOnEnabled -eq 1) {
            Write-Log "${Server}\${Instance}: Always On is ENABLED"

            # Additional checks for AG details
            $agStatusQuery = @"
SELECT ag.name AS AGName,
       ar.replica_server_name AS ReplicaName,
       rs.role_desc AS ReplicaRole,
       rs.synchronization_health_desc AS SynchronizationHealth
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar
  ON ag.group_id = ar.group_id
JOIN sys.dm_hadr_availability_replica_states rs
  ON ar.replica_id = rs.replica_id;
"@
            $agStatus = Invoke-SqlQuery -Server $Server -Instance $Instance -Query $agStatusQuery

            if ($agStatus.Rows.Count -gt 0) {
                foreach ($row in $agStatus) {
                    Write-Log "${Server}\${Instance}: AG: $($row.AGName), Replica: $($row.ReplicaName), Role: $($row.ReplicaRole), Health: $($row.SynchronizationHealth)"
                }

                # Check databases in the AG for synchronization status
                Check-AgDatabases -Server $Server -Instance $Instance
            } else {
                Write-Log "${Server}\${Instance}: No Availability Groups found."
            }

            # Check standalone databases (databases not in AG)
            Check-StandaloneDatabases -Server $Server -Instance $Instance
        } else {
            Write-Log "${Server}\${Instance}: Always On is NOT ENABLED" "INFO"

            # Check all databases as standalone since AG is disabled
            Check-StandaloneDatabases -Server $Server -Instance $Instance
        }
    } catch {
        Write-Log "ERROR: Unable to check Always On status for ${Server}\${Instance} - $($_.Exception.Message)" "ERROR"
    }

    Write-Log "Finished checks for ${Server}\${Instance}"
}

# Main execution logic
Write-Log "Starting SQL Server checks for ${Server}"

# Dynamically retrieve instances for the server
$instances = Get-SqlInstances -Server $Server

foreach ($instance in $instances) {
    Check-SqlInstance -Server $Server -Instance $instance
}

Write-Log "All SQL Server checks completed for ${Server}"

# Add separators for Summary
Write-Log "SUMMARY OF SQL SERVER CHECKS" "SEPARATOR"

# Output summary to the log file
if ($global:summary.Count -gt 0) {
    $global:summary | ForEach-Object { 
        Write-Log "$($_.Server)\$($_.Instance) - Status: $($_.Status), Version: $($_.Version)"
    }
} else {
    Write-Log "No summary information available. Ensure the checks ran properly." "WARNING"
}

Write-Log "END OF LOG" "SEPARATOR"
