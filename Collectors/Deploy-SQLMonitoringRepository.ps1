<#
===============================================================================
 SQL Monitoring Tool - Repository Deployment PowerShell Script

 Purpose:
     Runs the SQLMonitoring database/table deployment script from the jump server.

 Requirements:
     - PowerShell 5.1 or PowerShell 7
     - dbatools module installed
     - Permissions to create database/tables on the local SQL Server instance

 Example:
     .\Deploy-SQLMonitoringRepository.ps1 -CentralSqlInstance "localhost"

 Named instance example:
     .\Deploy-SQLMonitoringRepository.ps1 -CentralSqlInstance "localhost\SQL2019"

 Optional custom script path:
     .\Deploy-SQLMonitoringRepository.ps1 `
         -CentralSqlInstance "localhost" `
         -SqlScriptPath "C:\SQLMonitoring\Database\Create-SQLMonitoringRepository.sql"
===============================================================================
#>

[CmdletBinding()]
param
(
    [Parameter(Mandatory = $false)]
    [string]$CentralSqlInstance = "localhost",

    [Parameter(Mandatory = $false)]
    [string]$SqlScriptPath = "C:\SQLMonitoring\Database\Create-SQLMonitoringRepository.sql",

    [Parameter(Mandatory = $false)]
    [int]$QueryTimeoutSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "[SUCCESS] $Message" -ForegroundColor Green
}

function Write-Fail {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

try {
    Write-Info "Starting SQLMonitoring repository deployment."
    Write-Info "Central SQL Instance: $CentralSqlInstance"
    Write-Info "SQL Script Path: $SqlScriptPath"

    if (-not (Get-Module -ListAvailable -Name dbatools)) {
        throw "dbatools module is not installed. Install it using: Install-Module dbatools -Scope AllUsers"
    }

    Import-Module dbatools

    if (-not (Test-Path -Path $SqlScriptPath)) {
        throw "SQL script file was not found: $SqlScriptPath"
    }

    Write-Info "Testing SQL connection..."
    $connectionTest = Test-DbaConnection -SqlInstance $CentralSqlInstance

    if (-not $connectionTest.ConnectSuccess) {
        throw "Could not connect to SQL instance: $CentralSqlInstance"
    }

    Write-Success "Connection successful."

    Write-Info "Running deployment script..."
    Invoke-DbaQuery `
        -SqlInstance $CentralSqlInstance `
        -Database master `
        -File $SqlScriptPath `
        -QueryTimeout $QueryTimeoutSeconds

    Write-Success "SQLMonitoring repository deployment completed."

    Write-Info "Validating created objects..."
    $validationQuery = @"
SELECT
    DB_NAME() AS DatabaseName,
    s.name AS SchemaName,
    t.name AS TableName,
    SUM(p.rows) AS RowCount
FROM SQLMonitoring.sys.tables t
JOIN SQLMonitoring.sys.schemas s
    ON t.schema_id = s.schema_id
LEFT JOIN SQLMonitoring.sys.partitions p
    ON t.object_id = p.object_id
   AND p.index_id IN (0,1)
WHERE t.name IN
(
    'MonitoredInstances',
    'CollectionRunHistory',
    'MetricSnapshot',
    'MetricTextSnapshot',
    'AnomalyEvents'
)
GROUP BY
    s.name,
    t.name
ORDER BY
    s.name,
    t.name;
"@

    $objects = Invoke-DbaQuery `
        -SqlInstance $CentralSqlInstance `
        -Database master `
        -Query $validationQuery `
        -QueryTimeout 30

    $objects | Format-Table -AutoSize
}
catch {
    Write-Fail $_.Exception.Message
    throw
}
