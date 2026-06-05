<#
===============================================================================
 SQLSentinel - Database IO Collector
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

$CollectorName = "Collect-DatabaseIO"

function Write-Info { param([string]$Message) Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-Fail { param([string]$Message) Write-Host "[ERROR] $Message" -ForegroundColor Red }

function Start-CollectionRun {
    param(
        [string]$CentralSqlInstance,
        [string]$CentralDatabase,
        [pscredential]$SqlCredential,
        [int]$InstanceId,
        [string]$CollectorName
    )

    Invoke-DbaQuery `
        -SqlInstance $CentralSqlInstance `
        -SqlCredential $SqlCredential `
        -Database $CentralDatabase `
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
        -As SingleValue
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

    $safeError = if ($null -eq $ErrorMessage) { "NULL" } else { "N'" + $ErrorMessage.Replace("'", "''") + "'" }

    Invoke-DbaQuery `
        -SqlInstance $CentralSqlInstance `
        -SqlCredential $SqlCredential `
        -Database $CentralDatabase `
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

try {
    if (-not (Test-Path $ConfigPath)) {
        throw "Config file not found: $ConfigPath"
    }

    Import-Module dbatools

    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

    $CentralSqlInstance = $config.CentralSqlInstance
    $CentralDatabase = $config.CentralDatabase

    $QueryTimeout = 15
    $MaximumFiles = 200

    if ($null -ne $config.Collectors -and
        $config.Collectors.PSObject.Properties.Name -contains "DatabaseIO") {

        $databaseIoConfig = $config.Collectors.DatabaseIO

        if ($databaseIoConfig.PSObject.Properties.Name -contains "QueryTimeoutSeconds") {
            $QueryTimeout = [int]$databaseIoConfig.QueryTimeoutSeconds
        }

        if ($databaseIoConfig.PSObject.Properties.Name -contains "MaximumFiles") {
            $MaximumFiles = [int]$databaseIoConfig.MaximumFiles
        }
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

    $instances = Invoke-DbaQuery `
        -SqlInstance $CentralSqlInstance `
        -SqlCredential $SqlCredential `
        -Database $CentralDatabase `
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

        Write-Info "Collecting database IO metrics from $TargetInstance"

        try {
            $CollectionRunId = Start-CollectionRun `
                -CentralSqlInstance $CentralSqlInstance `
                -CentralDatabase $CentralDatabase `
                -SqlCredential $SqlCredential `
                -InstanceId $InstanceId `
                -CollectorName $CollectorName

            $ioQuery = @"
SELECT TOP ($MaximumFiles)
    CaptureTime = SYSDATETIME(),
    DatabaseName = DB_NAME(vfs.database_id),
    LogicalFileName = mf.name,
    FileType = mf.type_desc,
    NumReads = CAST(ISNULL(vfs.num_of_reads, 0) AS decimal(19,2)),
    NumWrites = CAST(ISNULL(vfs.num_of_writes, 0) AS decimal(19,2)),
    BytesRead = CAST(ISNULL(vfs.num_of_bytes_read, 0) AS decimal(19,2)),
    BytesWritten = CAST(ISNULL(vfs.num_of_bytes_written, 0) AS decimal(19,2)),
    IoStallReadMs = CAST(ISNULL(vfs.io_stall_read_ms, 0) AS decimal(19,2)),
    IoStallWriteMs = CAST(ISNULL(vfs.io_stall_write_ms, 0) AS decimal(19,2)),
    IoStallTotalMs = CAST(ISNULL(vfs.io_stall, 0) AS decimal(19,2)),
    AvgReadLatencyMs =
        CAST(
            CASE
                WHEN ISNULL(vfs.num_of_reads, 0) = 0 THEN 0
                ELSE CAST(ISNULL(vfs.io_stall_read_ms, 0) AS decimal(19,2))
                     / CAST(vfs.num_of_reads AS decimal(19,2))
            END AS decimal(19,2)
        ),
    AvgWriteLatencyMs =
        CAST(
            CASE
                WHEN ISNULL(vfs.num_of_writes, 0) = 0 THEN 0
                ELSE CAST(ISNULL(vfs.io_stall_write_ms, 0) AS decimal(19,2))
                     / CAST(vfs.num_of_writes AS decimal(19,2))
            END AS decimal(19,2)
        ),
    AvgIoLatencyMs =
        CAST(
            CASE
                WHEN (ISNULL(vfs.num_of_reads, 0) + ISNULL(vfs.num_of_writes, 0)) = 0 THEN 0
                ELSE CAST(ISNULL(vfs.io_stall, 0) AS decimal(19,2))
                     / CAST((vfs.num_of_reads + vfs.num_of_writes) AS decimal(19,2))
            END AS decimal(19,2)
        )
FROM sys.dm_io_virtual_file_stats(NULL, NULL) AS vfs
INNER JOIN sys.master_files AS mf
    ON mf.database_id = vfs.database_id
   AND mf.file_id = vfs.file_id
INNER JOIN sys.databases AS d
    ON d.database_id = vfs.database_id
WHERE vfs.database_id > 4
  AND d.state_desc = 'ONLINE'
  AND
  (
      vfs.num_of_reads > 0
      OR vfs.num_of_writes > 0
      OR vfs.io_stall > 0
  )
ORDER BY
    vfs.io_stall DESC,
    (vfs.num_of_reads + vfs.num_of_writes) DESC;
"@

            $ioRows = Invoke-DbaQuery `
                -SqlInstance $TargetInstance `
                -SqlCredential $SqlCredential `
                -Database master `
                -Query $ioQuery `
                -QueryTimeout $QueryTimeout

            $captureTime = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

            foreach ($row in $ioRows) {

                $safeDatabaseName = if ([string]::IsNullOrWhiteSpace([string]$row.DatabaseName)) { "(unknown)" } else { [string]$row.DatabaseName }
                $safeLogicalFileName = if ([string]::IsNullOrWhiteSpace([string]$row.LogicalFileName)) { "(unknown)" } else { [string]$row.LogicalFileName }

                $safeDatabaseName = $safeDatabaseName.Replace("'", "''")
                $safeLogicalFileName = $safeLogicalFileName.Replace("'", "''")

                $metrics = @(
                    @{ CounterName = "NumReads"; Value = [decimal]$row.NumReads; Unit = "count" },
                    @{ CounterName = "NumWrites"; Value = [decimal]$row.NumWrites; Unit = "count" },
                    @{ CounterName = "BytesRead"; Value = [decimal]$row.BytesRead; Unit = "bytes" },
                    @{ CounterName = "BytesWritten"; Value = [decimal]$row.BytesWritten; Unit = "bytes" },
                    @{ CounterName = "IoStallReadMs"; Value = [decimal]$row.IoStallReadMs; Unit = "ms" },
                    @{ CounterName = "IoStallWriteMs"; Value = [decimal]$row.IoStallWriteMs; Unit = "ms" },
                    @{ CounterName = "IoStallTotalMs"; Value = [decimal]$row.IoStallTotalMs; Unit = "ms" },
                    @{ CounterName = "AvgReadLatencyMs"; Value = [decimal]$row.AvgReadLatencyMs; Unit = "ms" },
                    @{ CounterName = "AvgWriteLatencyMs"; Value = [decimal]$row.AvgWriteLatencyMs; Unit = "ms" },
                    @{ CounterName = "AvgIoLatencyMs"; Value = [decimal]$row.AvgIoLatencyMs; Unit = "ms" }
                )

                foreach ($metric in $metrics) {

                    Invoke-DbaQuery `
                        -SqlInstance $CentralSqlInstance `
                        -SqlCredential $SqlCredential `
                        -Database $CentralDatabase `
                        -Query @"
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
(
    $InstanceId,
    '$captureTime',
    N'$safeDatabaseName',
    'DatabaseFileIO',
    '$($metric.CounterName)',
    N'$safeLogicalFileName',
    'DatabaseIO',
    $($metric.Value),
    'Cumulative',
    '$($metric.Unit)',
    '$CollectorName'
);
"@ `
                        -QueryTimeout $QueryTimeout | Out-Null

                    $RowsCollected++
                }
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