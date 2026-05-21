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

    $safeError = if ($null -eq $ErrorMessage) { "NULL" } else { "N'" + $ErrorMessage.Replace("'", "''") + "'" }

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

    $QueryTimeout = 30
    if ($null -ne $config.Collectors -and
        $null -ne $config.Collectors.DatabaseIO -and
        $config.Collectors.DatabaseIO.PSObject.Properties.Name -contains "QueryTimeoutSeconds") {
        $QueryTimeout = [int]$config.Collectors.DatabaseIO.QueryTimeoutSeconds
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

            $ioQuery = @"
SELECT
    SYSDATETIME() AS CaptureTime,
    DatabaseName = d.name,
    LogicalFileName = mf.name,
    FileId = vfs.file_id,
    NumReads = vfs.num_of_reads,
    NumWrites = vfs.num_of_writes,
    BytesRead = vfs.num_of_bytes_read,
    BytesWritten = vfs.num_of_bytes_written,
    IoStallReadMs = vfs.io_stall_read_ms,
    IoStallWriteMs = vfs.io_stall_write_ms,
    IoStallTotalMs = vfs.io_stall,
    SizeOnDiskBytes = vfs.size_on_disk_bytes
FROM sys.dm_io_virtual_file_stats(NULL, NULL) AS vfs
INNER JOIN sys.master_files AS mf
    ON mf.database_id = vfs.database_id
   AND mf.file_id = vfs.file_id
INNER JOIN sys.databases AS d
    ON d.database_id = vfs.database_id
WHERE d.state_desc = 'ONLINE'
ORDER BY d.name, mf.name;
"@

            $ioMetrics = Invoke-DbaQuery `
                -SqlInstance $TargetInstance `
                -SqlCredential $SqlCredential `
                -Database master `
                -Query $ioQuery `
                -QueryTimeout $QueryTimeout

            $captureTime = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

            foreach ($row in $ioMetrics) {
                $databaseName = if ([string]::IsNullOrWhiteSpace([string]$row.DatabaseName)) { "(unknown)" } else { [string]$row.DatabaseName }
                $logicalFileName = if ([string]::IsNullOrWhiteSpace([string]$row.LogicalFileName)) { "(unknown)" } else { [string]$row.LogicalFileName }

                $safeDatabaseName = $databaseName.Replace("'", "''")
                $safeLogicalFileName = $logicalFileName.Replace("'", "''")

                $metrics = @(
                    @{ CounterName = "NumReads"; Value = [decimal]$row.NumReads; Unit = "count" },
                    @{ CounterName = "NumWrites"; Value = [decimal]$row.NumWrites; Unit = "count" },
                    @{ CounterName = "BytesRead"; Value = [decimal]$row.BytesRead; Unit = "bytes" },
                    @{ CounterName = "BytesWritten"; Value = [decimal]$row.BytesWritten; Unit = "bytes" },
                    @{ CounterName = "IoStallReadMs"; Value = [decimal]$row.IoStallReadMs; Unit = "ms" },
                    @{ CounterName = "IoStallWriteMs"; Value = [decimal]$row.IoStallWriteMs; Unit = "ms" },
                    @{ CounterName = "IoStallTotalMs"; Value = [decimal]$row.IoStallTotalMs; Unit = "ms" },
                    @{ CounterName = "SizeOnDiskBytes"; Value = [decimal]$row.SizeOnDiskBytes; Unit = "bytes" }
                )

                foreach ($metric in $metrics) {
                    $counterName = $metric.CounterName.Replace("'", "''")

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
    N'$safeDatabaseName',
    N'DatabaseFileIO',
    N'$counterName',
    N'$safeLogicalFileName',
    'DatabaseIO',
    $($metric.Value),
    'Cumulative',
    '$($metric.Unit)',
    '$CollectorName'
);
"@

                    Invoke-DbaQuery `
                        -SqlInstance $CentralSqlInstance `
                        -SqlCredential $SqlCredential `
                        -Database $CentralDatabase `
                        -Query $insertQuery `
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

            Write-Info "Completed $TargetInstance ($RowsCollected rows)"
        }
        catch {
            $err = $_.Exception.Message
            Write-Fail "Failed for ${TargetInstance}: $err"

            if ($CollectionRunId) {
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
