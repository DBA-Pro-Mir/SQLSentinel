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

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

function Start-CollectionRun {
    param(
        [string]$CentralSqlInstance,
        [string]$CentralDatabase,
        [pscredential]$SqlCredential,
        [int]$InstanceId,
        [string]$CollectorName
    )

    $query = @"
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
"@

    Invoke-DbaQuery `
        -SqlInstance $CentralSqlInstance `
        -SqlCredential $SqlCredential `
        -Database $CentralDatabase `
        -Query $query `
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

    $safeError = if ($null -eq $ErrorMessage) {
        "NULL"
    }
    else {
        "N'" + $ErrorMessage.Replace("'", "''") + "'"
    }

    $query = @"
UPDATE dbo.CollectionRunHistory
SET
    FinishedAt = SYSDATETIME(),
    Status = '$Status',
    RowsCollected = $RowsCollected,
    DurationMs = DATEDIFF(MILLISECOND, StartedAt, SYSDATETIME()),
    ErrorMessage = $safeError
WHERE CollectionRunId = $CollectionRunId;
"@

    Invoke-DbaQuery `
        -SqlInstance $CentralSqlInstance `
        -SqlCredential $SqlCredential `
        -Database $CentralDatabase `
        -Query $query | Out-Null
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

    $QueryTimeout = 15

    if (
        $null -ne $config.Collectors -and
        $config.Collectors.PSObject.Properties.Name -contains "DatabaseIO"
    ) {
        $databaseIoConfig = $config.Collectors.DatabaseIO

        if ($databaseIoConfig.PSObject.Properties.Name -contains "QueryTimeoutSeconds") {
            $QueryTimeout = [int]$databaseIoConfig.QueryTimeoutSeconds
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

    $instancesQuery = @"
SELECT
    InstanceId,
    InstanceName
FROM dbo.MonitoredInstances
WHERE IsEnabled = 1
ORDER BY InstanceName;
"@

    $instances = Invoke-DbaQuery `
        -SqlInstance $CentralSqlInstance `
        -SqlCredential $SqlCredential `
        -Database $CentralDatabase `
        -Query $instancesQuery `
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

            $captureTime = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

            $collectQuery = @"
IF OBJECT_ID('tempdb..#FileIoMetrics') IS NOT NULL
    DROP TABLE #FileIoMetrics;

SELECT
    DatabaseName = DB_NAME(vfs.database_id),
    LogicalFileName = mf.name,
    PhysicalName = mf.physical_name,
    FileType = mf.type_desc,
    NumReads = CAST(ISNULL(vfs.num_of_reads, 0) AS decimal(28,6)),
    NumWrites = CAST(ISNULL(vfs.num_of_writes, 0) AS decimal(28,6)),
    BytesRead = CAST(ISNULL(vfs.num_of_bytes_read, 0) AS decimal(28,6)),
    BytesWritten = CAST(ISNULL(vfs.num_of_bytes_written, 0) AS decimal(28,6)),
    IoStallReadMs = CAST(ISNULL(vfs.io_stall_read_ms, 0) AS decimal(28,6)),
    IoStallWriteMs = CAST(ISNULL(vfs.io_stall_write_ms, 0) AS decimal(28,6)),
    IoStallTotalMs = CAST(ISNULL(vfs.io_stall, 0) AS decimal(28,6)),
    AvgReadLatencyMs = CAST(
        CASE
            WHEN ISNULL(vfs.num_of_reads, 0) = 0 THEN 0
            ELSE CAST(ISNULL(vfs.io_stall_read_ms, 0) AS decimal(28,6)) / CAST(vfs.num_of_reads AS decimal(28,6))
        END AS decimal(28,6)
    ),
    AvgWriteLatencyMs = CAST(
        CASE
            WHEN ISNULL(vfs.num_of_writes, 0) = 0 THEN 0
            ELSE CAST(ISNULL(vfs.io_stall_write_ms, 0) AS decimal(28,6)) / CAST(vfs.num_of_writes AS decimal(28,6))
        END AS decimal(28,6)
    ),
    AvgIoLatencyMs = CAST(
        CASE
            WHEN (ISNULL(vfs.num_of_reads, 0) + ISNULL(vfs.num_of_writes, 0)) = 0 THEN 0
            ELSE CAST(ISNULL(vfs.io_stall, 0) AS decimal(28,6))
                 / CAST((vfs.num_of_reads + vfs.num_of_writes) AS decimal(28,6))
        END AS decimal(28,6)
    )
INTO #FileIoMetrics
FROM sys.dm_io_virtual_file_stats(NULL, NULL) AS vfs
INNER JOIN sys.master_files AS mf
    ON mf.database_id = vfs.database_id
   AND mf.file_id = vfs.file_id
INNER JOIN sys.databases AS d
    ON d.database_id = vfs.database_id
WHERE d.state_desc = 'ONLINE';

SELECT
    m.DatabaseName,
    m.LogicalFileName,
    m.PhysicalName,
    m.FileType,
    v.CounterName,
    v.MetricValue,
    v.Unit
FROM #FileIoMetrics AS m
CROSS APPLY
(
    VALUES
        ('NumReads', m.NumReads, 'count'),
        ('NumWrites', m.NumWrites, 'count'),
        ('BytesRead', m.BytesRead, 'bytes'),
        ('BytesWritten', m.BytesWritten, 'bytes'),
        ('IoStallReadMs', m.IoStallReadMs, 'ms'),
        ('IoStallWriteMs', m.IoStallWriteMs, 'ms'),
        ('IoStallTotalMs', m.IoStallTotalMs, 'ms'),
        ('AvgReadLatencyMs', m.AvgReadLatencyMs, 'ms'),
        ('AvgWriteLatencyMs', m.AvgWriteLatencyMs, 'ms'),
        ('AvgIoLatencyMs', m.AvgIoLatencyMs, 'ms')
) AS v(CounterName, MetricValue, Unit);

DROP TABLE #FileIoMetrics;
"@

            $fileIoRows = Invoke-DbaQuery `
                -SqlInstance $TargetInstance `
                -SqlCredential $SqlCredential `
                -Database master `
                -Query $collectQuery `
                -QueryTimeout $QueryTimeout

            foreach ($row in $fileIoRows) {
                $databaseNameValue = if ([string]::IsNullOrWhiteSpace([string]$row.DatabaseName)) {
                    "NULL"
                }
                else {
                    "N'" + ([string]$row.DatabaseName).Replace("'", "''") + "'"
                }

                $instanceNameValue = if ([string]::IsNullOrWhiteSpace([string]$row.LogicalFileName)) {
                    "NULL"
                }
                else {
                    "N'" + ([string]$row.LogicalFileName).Replace("'", "''") + "'"
                }

                $counterName = ([string]$row.CounterName).Replace("'", "''")
                $unit = ([string]$row.Unit).Replace("'", "''")
                $metricValue = [decimal]$row.MetricValue

                $insertQuery = @"
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
    $databaseNameValue,
    'DatabaseFileIO',
    N'$counterName',
    $instanceNameValue,
    'DatabaseIO',
    $metricValue,
    'Cumulative',
    '$unit',
    '$CollectorName'
);
"@

                Invoke-DbaQuery `
                    -SqlInstance $CentralSqlInstance `
                    -SqlCredential $SqlCredential `
                    -Database $CentralDatabase `
                    -Query $insertQuery `
                    -QueryTimeout 30 | Out-Null

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
            Write-Fail ("Failed on {0}: {1}" -f $TargetInstance, $err)

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

            continue
        }
    }

    Write-Info "$CollectorName finished"
}
catch {
    Write-Fail ("Fatal error in {0}: {1}" -f $CollectorName, $_.Exception.Message)
    throw
}