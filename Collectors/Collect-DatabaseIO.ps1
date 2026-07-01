<#
===============================================================================
 SQLSentinel - Database IO Collector
 Simplified version using sys.dm_io_virtual_file_stats only.
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

try {
    if (-not (Test-Path $ConfigPath)) {
        throw "Config file not found: $ConfigPath"
    }

    Import-Module dbatools

    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

    $CentralSqlInstance = $config.CentralSqlInstance
    $CentralDatabase = $config.CentralDatabase

    $QueryTimeout = 120
    $MaximumFiles = 25

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
    Write-Info "Using SQL login: $($config.SqlCredential.Username)"
    Write-Info "Collecting TOP $MaximumFiles database files where TotalIO > 0"

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

        Write-Info "Collecting database IO metrics from $TargetInstance"

        try {
            $CollectionRunId = Start-CollectionRun `
                -CentralSqlInstance $CentralSqlInstance `
                -CentralDatabase $CentralDatabase `
                -SqlCredential $SqlCredential `
                -InstanceId $InstanceId `
                -CollectorName $CollectorName

            $ioQuery = @"
;WITH FileIO AS
(
    SELECT
        CaptureTime = SYSDATETIME(),
        DatabaseName = d.name,
        LogicalFileName = CONCAT('file_id_', vfs.file_id),
        PhysicalName = '(unavailable)',
        DriveLetter = '(unknown)',
        FileType = 'UNKNOWN',
        FileSizeMB = CAST(0 AS decimal(19,2)),
        FileSizeGB = CAST(0 AS decimal(19,2)),
        NumReads = CAST(ISNULL(vfs.num_of_reads, 0) AS decimal(19,2)),
        NumWrites = CAST(ISNULL(vfs.num_of_writes, 0) AS decimal(19,2)),
        TotalIO = CAST(ISNULL(vfs.num_of_reads, 0) + ISNULL(vfs.num_of_writes, 0) AS decimal(19,2)),
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
    INNER JOIN sys.databases AS d
        ON d.database_id = vfs.database_id
    WHERE d.database_id > 4
      AND d.state_desc = 'ONLINE'
      AND d.source_database_id IS NULL
)
SELECT TOP ($MaximumFiles)
    CaptureTime,
    DatabaseName,
    LogicalFileName,
    PhysicalName,
    DriveLetter,
    FileType,
    FileSizeMB,
    FileSizeGB,
    NumReads,
    NumWrites,
    TotalIO,
    BytesRead,
    BytesWritten,
    IoStallReadMs,
    IoStallWriteMs,
    IoStallTotalMs,
    AvgReadLatencyMs,
    AvgWriteLatencyMs,
    AvgIoLatencyMs
FROM FileIO
WHERE TotalIO > 0
ORDER BY
    TotalIO DESC,
    IoStallTotalMs DESC,
    AvgIoLatencyMs DESC;
"@

            $ioRows = Invoke-SentinelQuery `
                -SqlInstance $TargetInstance `
                -Database master `
                -SqlCredential $SqlCredential `
                -Query $ioQuery `
                -QueryTimeout $QueryTimeout

            $ioRows = @($ioRows)

            Write-Info ("Returned IO rows from {0}: {1}" -f $TargetInstance, $ioRows.Count)

            $captureTime = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

            foreach ($row in $ioRows) {

                $safeDatabaseName = if ([string]::IsNullOrWhiteSpace([string]$row.DatabaseName)) { "(unknown)" } else { [string]$row.DatabaseName }
                $safeLogicalFileName = if ([string]::IsNullOrWhiteSpace([string]$row.LogicalFileName)) { "(unknown)" } else { [string]$row.LogicalFileName }
                $safePhysicalName = if ([string]::IsNullOrWhiteSpace([string]$row.PhysicalName)) { "(unknown)" } else { [string]$row.PhysicalName }
                $safeDriveLetter = if ([string]::IsNullOrWhiteSpace([string]$row.DriveLetter)) { "(unknown)" } else { [string]$row.DriveLetter }

                $safeDatabaseName = $safeDatabaseName.Replace("'", "''")
                $safeLogicalFileName = $safeLogicalFileName.Replace("'", "''")
                $safePhysicalName = $safePhysicalName.Replace("'", "''")
                $safeDriveLetter = $safeDriveLetter.Replace("'", "''")

                $detailText = @"
DatabaseName: $safeDatabaseName
LogicalFileName: $safeLogicalFileName
PhysicalName: $safePhysicalName
DriveLetter: $safeDriveLetter
FileType: $($row.FileType)
FileSizeGB: $($row.FileSizeGB)
TotalIO: $($row.TotalIO)
AvgReadLatencyMs: $($row.AvgReadLatencyMs)
AvgWriteLatencyMs: $($row.AvgWriteLatencyMs)
AvgIoLatencyMs: $($row.AvgIoLatencyMs)
"@

                $safeDetails = $detailText.Replace("'", "''")

                $metrics = @(
                    @{ CounterName = "FileSizeMB"; Value = [decimal]$row.FileSizeMB; Unit = "MB" },
                    @{ CounterName = "FileSizeGB"; Value = [decimal]$row.FileSizeGB; Unit = "GB" },
                    @{ CounterName = "NumReads"; Value = [decimal]$row.NumReads; Unit = "count" },
                    @{ CounterName = "NumWrites"; Value = [decimal]$row.NumWrites; Unit = "count" },
                    @{ CounterName = "TotalIO"; Value = [decimal]$row.TotalIO; Unit = "count" },
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

                    Invoke-SentinelQuery `
                        -SqlInstance $CentralSqlInstance `
                        -Database $CentralDatabase `
                        -SqlCredential $SqlCredential `
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

                $severity =
                    if ([decimal]$row.AvgWriteLatencyMs -ge 20 -or [decimal]$row.AvgReadLatencyMs -ge 20) {
                        "Critical"
                    }
                    elseif ([decimal]$row.AvgWriteLatencyMs -ge 10 -or [decimal]$row.AvgReadLatencyMs -ge 10) {
                        "Warning"
                    }
                    else {
                        "Info"
                    }

                Invoke-SentinelQuery `
                    -SqlInstance $CentralSqlInstance `
                    -Database $CentralDatabase `
                    -SqlCredential $SqlCredential `
                    -Query @"
INSERT INTO dbo.MetricTextSnapshot
(
    InstanceId,
    CaptureTime,
    DatabaseName,
    MetricCategory,
    DetailType,
    Severity,
    NumericValue1,
    NumericValue2,
    Details,
    SourceCollector
)
VALUES
(
    $InstanceId,
    '$captureTime',
    N'$safeDatabaseName',
    'DatabaseIO',
    'DatabaseFileIODetail',
    '$severity',
    $([decimal]$row.AvgIoLatencyMs),
    $([decimal]$row.TotalIO),
    N'$safeDetails',
    '$CollectorName'
);
"@ `
                    -QueryTimeout $QueryTimeout | Out-Null

                $RowsCollected++
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