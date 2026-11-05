<#
===============================================================================
 SQLSentinel - Storage & Capacity Collector
===============================================================================
#>

[CmdletBinding()]
param
(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = ".\Config\SQLSentinel.config.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$CollectorName = "Collect-StorageCapacity"

function Write-Info { param([string]$Message) Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-Fail { param([string]$Message) Write-Host "[ERROR] $Message" -ForegroundColor Red }

function Invoke-SentinelQuery {
    param(
        [string]$SqlInstance,
        [string]$Database,
        [string]$Query,
        [pscredential]$SqlCredential,
        [int]$QueryTimeout = 120,
        [switch]$AsSingleValue
    )

    $params = @{
        SqlInstance     = $SqlInstance
        Database        = $Database
        Query           = $Query
        QueryTimeout    = $QueryTimeout
        EnableException = $true
    }

    if ($null -ne $SqlCredential) {
        $params.SqlCredential = $SqlCredential
    }

    if ($AsSingleValue) {
        $params.As = "SingleValue"
    }

    Invoke-DbaQuery @params
}

function Start-CollectionRun {
    param(
        [string]$CentralSqlInstance,
        [string]$CentralDatabase,
        [pscredential]$SqlCredential,
        [int]$InstanceId,
        [string]$CollectorName
    )

    Invoke-SentinelQuery `
        -SqlInstance $CentralSqlInstance `
        -Database $CentralDatabase `
        -SqlCredential $SqlCredential `
        -Query @"
INSERT INTO dbo.CollectionRunHistory
(
    CollectorName,
    InstanceId,
    StartedAt,
    Status
)
OUTPUT inserted.CollectionRunId
VALUES
(
    '$CollectorName',
    $InstanceId,
    SYSDATETIME(),
    'Running'
);
"@ `
        -AsSingleValue
}

function Complete-CollectionRun {
    param(
        [string]$CentralSqlInstance,
        [string]$CentralDatabase,
        [pscredential]$SqlCredential,
        [bigint]$CollectionRunId,
        [string]$Status,
        [int]$RowsCollected,
        [string]$ErrorMessage = $null
    )

    $safeError = if ($null -eq $ErrorMessage) {
        "NULL"
    }
    else {
        "N'" + $ErrorMessage.Replace("'", "''") + "'"
    }

    Invoke-SentinelQuery `
        -SqlInstance $CentralSqlInstance `
        -Database $CentralDatabase `
        -SqlCredential $SqlCredential `
        -Query @"
UPDATE dbo.CollectionRunHistory
SET
    FinishedAt = SYSDATETIME(),
    Status = '$Status',
    RowsCollected = $RowsCollected,
    DurationMs = DATEDIFF(MILLISECOND, StartedAt, SYSDATETIME()),
    ErrorMessage = $safeError
WHERE CollectionRunId = $CollectionRunId;
"@ | Out-Null
}

function Convert-ToSqlNumber {
    param([object]$Value)

    if ($null -eq $Value -or [System.DBNull]::Value.Equals($Value)) {
        return "0"
    }

    return ([convert]::ToDecimal($Value)).ToString(
        [System.Globalization.CultureInfo]::InvariantCulture
    )
}

function Write-MetricBatch {
    param(
        [string]$CentralSqlInstance,
        [string]$CentralDatabase,
        [pscredential]$SqlCredential,
        [int]$QueryTimeout,
        [System.Collections.Generic.List[string]]$Rows
    )

    if ($Rows.Count -eq 0) {
        return
    }

    $valuesText = $Rows -join ", "

    $query = @"
INSERT INTO dbo.MetricSnapshot
(
    InstanceId,
    CaptureTime,
    DatabaseName,
    ObjectName,
    CounterName,
    InstanceName,
    MetricCategory,
    MetricValue,
    MetricType,
    Unit,
    SourceCollector
)
VALUES
$valuesText;
"@

    Invoke-SentinelQuery `
        -SqlInstance $CentralSqlInstance `
        -Database $CentralDatabase `
        -SqlCredential $SqlCredential `
        -Query $query `
        -QueryTimeout $QueryTimeout | Out-Null
}

try {
    if (-not (Test-Path $ConfigPath)) {
        throw "Config file not found: $ConfigPath"
    }

    if (-not (Get-Module -ListAvailable -Name dbatools)) {
        throw "dbatools module is not installed."
    }

    Import-Module dbatools

    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

    $CentralSqlInstance = $config.CentralSqlInstance
    $CentralDatabase = $config.CentralDatabase
    $QueryTimeout = 120
    $DatabaseBatchSize = 300

    if ($null -ne $config.Collectors -and
        $config.Collectors.PSObject.Properties.Name -contains "StorageCapacity") {

        $storageConfig = $config.Collectors.StorageCapacity

        if ($storageConfig.PSObject.Properties.Name -contains "QueryTimeoutSeconds") {
            $QueryTimeout = [int]$storageConfig.QueryTimeoutSeconds
        }

        if ($storageConfig.PSObject.Properties.Name -contains "DatabaseBatchSize") {
            $DatabaseBatchSize = [int]$storageConfig.DatabaseBatchSize
        }
    }

    if ($DatabaseBatchSize -lt 1 -or $DatabaseBatchSize -gt 300) {
        $DatabaseBatchSize = 300
    }

    $SqlCredential = $null

    if ($config.SqlCredential.Username -and $config.SqlCredential.Password) {
        $SqlCredential = New-Object System.Management.Automation.PSCredential(
            $config.SqlCredential.Username,
            (ConvertTo-SecureString $config.SqlCredential.Password -AsPlainText -Force)
        )
    }

    Write-Info "Starting $CollectorName"
    Write-Info "Repository: $CentralSqlInstance / $CentralDatabase"

    $instances = Invoke-SentinelQuery `
        -SqlInstance $CentralSqlInstance `
        -Database $CentralDatabase `
        -SqlCredential $SqlCredential `
        -Query @"
SELECT
    InstanceId,
    InstanceName
FROM dbo.MonitoredInstances
WHERE IsEnabled = 1
ORDER BY InstanceName;
"@ `
        -QueryTimeout 30

    foreach ($instance in $instances) {

        $InstanceId = [int]$instance.InstanceId
        $TargetInstance = [string]$instance.InstanceName
        $RowsCollected = 0
        $CollectionRunId = $null
        $captureTime = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

        Write-Info "Collecting storage capacity from $TargetInstance"

        try {
            $CollectionRunId = Start-CollectionRun `
                -CentralSqlInstance $CentralSqlInstance `
                -CentralDatabase $CentralDatabase `
                -SqlCredential $SqlCredential `
                -InstanceId $InstanceId `
                -CollectorName $CollectorName

            $permissionQuery = @"
SELECT
    HasViewServerState =
        HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER STATE'),
    HasViewAnyDefinition =
        HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW ANY DEFINITION'),
    HasViewAnyDatabase =
        HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW ANY DATABASE');
"@

            $permissionResult = Invoke-SentinelQuery `
                -SqlInstance $TargetInstance `
                -Database master `
                -SqlCredential $SqlCredential `
                -Query $permissionQuery `
                -QueryTimeout 30

            if ([int]$permissionResult.HasViewServerState -ne 1) {
                throw "sqlsentinel is missing VIEW SERVER STATE on $TargetInstance."
            }

            if ([int]$permissionResult.HasViewAnyDefinition -ne 1) {
                throw "sqlsentinel is missing VIEW ANY DEFINITION on $TargetInstance. Run: GRANT VIEW ANY DEFINITION TO [sqlsentinel];"
            }

            if ([int]$permissionResult.HasViewAnyDatabase -ne 1) {
                throw "sqlsentinel is missing VIEW ANY DATABASE on $TargetInstance. Run: GRANT VIEW ANY DATABASE TO [sqlsentinel];"
            }

            $volumeQuery = @"
;WITH VolumeData AS
(
    SELECT DISTINCT
        VolumeName = vs.volume_mount_point,
        TotalGB =
            CAST(vs.total_bytes / 1073741824.0 AS decimal(19,2)),
        FreeGB =
            CAST(vs.available_bytes / 1073741824.0 AS decimal(19,2)),
        UsedGB =
            CAST((vs.total_bytes - vs.available_bytes) / 1073741824.0 AS decimal(19,2)),
        FreePercent =
            CAST(
                CASE
                    WHEN vs.total_bytes = 0 THEN 0
                    ELSE (vs.available_bytes * 100.0) / vs.total_bytes
                END
                AS decimal(19,2)
            )
    FROM sys.master_files AS mf
    CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) AS vs
    WHERE vs.volume_mount_point IS NOT NULL
)
SELECT
    VolumeName,
    TotalGB,
    UsedGB,
    FreeGB,
    FreePercent
FROM VolumeData
ORDER BY VolumeName;
"@

            $databaseQuery = @"
SELECT
    DatabaseName = d.name,
    DataSizeGB =
        CAST(
            SUM(CASE WHEN mf.type = 0 THEN mf.size ELSE 0 END)
            * 8.0 / 1024.0 / 1024.0
            AS decimal(19,2)
        ),
    LogSizeGB =
        CAST(
            SUM(CASE WHEN mf.type = 1 THEN mf.size ELSE 0 END)
            * 8.0 / 1024.0 / 1024.0
            AS decimal(19,2)
        ),
    TotalSizeGB =
        CAST(
            SUM(mf.size)
            * 8.0 / 1024.0 / 1024.0
            AS decimal(19,2)
        )
FROM sys.databases AS d
INNER JOIN sys.master_files AS mf
    ON mf.database_id = d.database_id
WHERE d.database_id > 4
  AND d.source_database_id IS NULL
GROUP BY d.name
ORDER BY TotalSizeGB DESC, d.name;
"@

            $volumeRows = @(
                Invoke-SentinelQuery `
                    -SqlInstance $TargetInstance `
                    -Database master `
                    -SqlCredential $SqlCredential `
                    -Query $volumeQuery `
                    -QueryTimeout $QueryTimeout
            )

            $databaseRows = @(
                Invoke-SentinelQuery `
                    -SqlInstance $TargetInstance `
                    -Database master `
                    -SqlCredential $SqlCredential `
                    -Query $databaseQuery `
                    -QueryTimeout $QueryTimeout
            )

            Write-Info ("Returned volumes from {0}: {1}" -f $TargetInstance, $volumeRows.Count)
            Write-Info ("Returned databases from {0}: {1}" -f $TargetInstance, $databaseRows.Count)

            if ($volumeRows.Count -eq 0 -and $databaseRows.Count -eq 0) {
                throw "Storage collector returned no volume or database rows from $TargetInstance."
            }


            $metricRows = New-Object 'System.Collections.Generic.List[string]'

            foreach ($row in $volumeRows) {

                $volumeName = if ([string]::IsNullOrWhiteSpace([string]$row.VolumeName)) {
                    "(unknown)"
                }
                else {
                    [string]$row.VolumeName
                }

                $safeVolumeName = $volumeName.Replace("'", "''")

                $volumeMetrics = @(
                    @{ CounterName = "TotalGB"; Value = $row.TotalGB; Unit = "GB" },
                    @{ CounterName = "UsedGB"; Value = $row.UsedGB; Unit = "GB" },
                    @{ CounterName = "FreeGB"; Value = $row.FreeGB; Unit = "GB" },
                    @{ CounterName = "FreePercent"; Value = $row.FreePercent; Unit = "percent" }
                )

                foreach ($metric in $volumeMetrics) {
                    $value = Convert-ToSqlNumber $metric.Value

                    $metricRows.Add(
                        "($InstanceId, '$captureTime', NULL, N'StorageVolume', N'$($metric.CounterName)', N'$safeVolumeName', N'StorageVolume', $value, N'Gauge', N'$($metric.Unit)', N'$CollectorName')"
                    )
                }
            }

            if ($metricRows.Count -gt 0) {
                Write-MetricBatch `
                    -CentralSqlInstance $CentralSqlInstance `
                    -CentralDatabase $CentralDatabase `
                    -SqlCredential $SqlCredential `
                    -QueryTimeout $QueryTimeout `
                    -Rows $metricRows

                $RowsCollected += $metricRows.Count
                $metricRows.Clear()
            }

            $databasesInBatch = 0

            foreach ($row in $databaseRows) {

                $databaseName = if ([string]::IsNullOrWhiteSpace([string]$row.DatabaseName)) {
                    "(unknown)"
                }
                else {
                    [string]$row.DatabaseName
                }

                $safeDatabaseName = $databaseName.Replace("'", "''")

                $databaseMetrics = @(
                    @{ CounterName = "DataSizeGB"; Value = $row.DataSizeGB },
                    @{ CounterName = "LogSizeGB"; Value = $row.LogSizeGB },
                    @{ CounterName = "TotalSizeGB"; Value = $row.TotalSizeGB }
                )

                foreach ($metric in $databaseMetrics) {
                    $value = Convert-ToSqlNumber $metric.Value

                    $metricRows.Add(
                        "($InstanceId, '$captureTime', N'$safeDatabaseName', N'DatabaseSize', N'$($metric.CounterName)', NULL, N'DatabaseSize', $value, N'Gauge', N'GB', N'$CollectorName')"
                    )
                }

                $databasesInBatch++

                if ($databasesInBatch -ge $DatabaseBatchSize) {
                    Write-MetricBatch `
                        -CentralSqlInstance $CentralSqlInstance `
                        -CentralDatabase $CentralDatabase `
                        -SqlCredential $SqlCredential `
                        -QueryTimeout $QueryTimeout `
                        -Rows $metricRows

                    $RowsCollected += $metricRows.Count
                    $metricRows.Clear()
                    $databasesInBatch = 0
                }
            }

            if ($metricRows.Count -gt 0) {
                Write-MetricBatch `
                    -CentralSqlInstance $CentralSqlInstance `
                    -CentralDatabase $CentralDatabase `
                    -SqlCredential $SqlCredential `
                    -QueryTimeout $QueryTimeout `
                    -Rows $metricRows

                $RowsCollected += $metricRows.Count
                $metricRows.Clear()
            }

            Complete-CollectionRun `
                -CentralSqlInstance $CentralSqlInstance `
                -CentralDatabase $CentralDatabase `
                -SqlCredential $SqlCredential `
                -CollectionRunId $CollectionRunId `
                -Status "Success" `
                -RowsCollected $RowsCollected

            Write-Info "Completed $TargetInstance. Rows collected: $RowsCollected"
        }
        catch {
            $err = $_.Exception.Message
            Write-Fail ("Failed for {0}: {1}" -f $TargetInstance, $err)

            if ($null -ne $CollectionRunId) {
                Complete-CollectionRun `
                    -CentralSqlInstance $CentralSqlInstance `
                    -CentralDatabase $CentralDatabase `
                    -SqlCredential $SqlCredential `
                    -CollectionRunId $CollectionRunId `
                    -Status "Failed" `
                    -RowsCollected $RowsCollected `
                    -ErrorMessage $err
            }
        }
    }

    Write-Info "$CollectorName completed"
}
catch {
    Write-Fail "$CollectorName failed: $($_.Exception.Message)"
    throw
}
