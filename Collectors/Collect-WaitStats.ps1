<#
===============================================================================
 SQLSentinel - Wait Statistics Collector
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

$CollectorName = "Collect-WaitStats"

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
    $MaximumWaitTypes = 100

    if (
        $null -ne $config.Collectors -and
        $config.Collectors.PSObject.Properties.Name -contains "WaitStats"
    ) {
        $waitStatsConfig = $config.Collectors.WaitStats

        if ($waitStatsConfig.PSObject.Properties.Name -contains "QueryTimeoutSeconds") {
            $QueryTimeout = [int]$waitStatsConfig.QueryTimeoutSeconds
        }

        if ($waitStatsConfig.PSObject.Properties.Name -contains "MaximumWaitTypes") {
            $MaximumWaitTypes = [int]$waitStatsConfig.MaximumWaitTypes
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

        Write-Info "Collecting wait statistics from $TargetInstance"

        try {
            $CollectionRunId = Start-CollectionRun `
                -CentralSqlInstance $CentralSqlInstance `
                -CentralDatabase $CentralDatabase `
                -SqlCredential $SqlCredential `
                -InstanceId $InstanceId `
                -CollectorName $CollectorName

            $waitStatsQuery = @"
SELECT TOP ($MaximumWaitTypes)
    SYSDATETIME() AS CaptureTime,
    wait_type,
    waiting_tasks_count,
    wait_time_ms,
    signal_wait_time_ms,
    ResourceWaitTimeMs = wait_time_ms - signal_wait_time_ms,
    max_wait_time_ms
FROM sys.dm_os_wait_stats
WHERE wait_type NOT IN
(
    'BROKER_EVENTHANDLER',
    'BROKER_RECEIVE_WAITFOR',
    'BROKER_TASK_STOP',
    'BROKER_TO_FLUSH',
    'BROKER_TRANSMITTER',
    'CHECKPOINT_QUEUE',
    'CHKPT',
    'CLR_AUTO_EVENT',
    'CLR_MANUAL_EVENT',
    'CLR_SEMAPHORE',
    'DBMIRROR_DBM_EVENT',
    'DBMIRROR_EVENTS_QUEUE',
    'DBMIRROR_WORKER_QUEUE',
    'DIRTY_PAGE_POLL',
    'DISPATCHER_QUEUE_SEMAPHORE',
    'EXECSYNC',
    'FSAGENT',
    'FT_IFTS_SCHEDULER_IDLE_WAIT',
    'FT_IFTSHC_MUTEX',
    'HADR_CLUSAPI_CALL',
    'HADR_FILESTREAM_IOMGR_IOCOMPLETION',
    'HADR_LOGCAPTURE_WAIT',
    'HADR_NOTIFICATION_DEQUEUE',
    'HADR_TIMER_TASK',
    'HADR_WORK_QUEUE',
    'KSOURCE_WAKEUP',
    'LAZYWRITER_SLEEP',
    'LOGMGR_QUEUE',
    'MEMORY_ALLOCATION_EXT',
    'ONDEMAND_TASK_QUEUE',
    'PARALLEL_REDO_DRAIN_WORKER',
    'PARALLEL_REDO_LOG_CACHE',
    'PARALLEL_REDO_TRAN_LIST',
    'PARALLEL_REDO_WORKER_SYNC',
    'PARALLEL_REDO_WORKER_WAIT_WORK',
    'PREEMPTIVE_OS_FLUSHFILEBUFFERS',
    'PREEMPTIVE_XE_GETTARGETSTATE',
    'PWAIT_ALL_COMPONENTS_INITIALIZED',
    'PWAIT_DIRECTLOGCONSUMER_GETNEXT',
    'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP',
    'QDS_ASYNC_QUEUE',
    'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP',
    'REQUEST_FOR_DEADLOCK_SEARCH',
    'RESOURCE_QUEUE',
    'SERVER_IDLE_CHECK',
    'SLEEP_BPOOL_FLUSH',
    'SLEEP_DBSTARTUP',
    'SLEEP_DCOMSTARTUP',
    'SLEEP_MASTERDBREADY',
    'SLEEP_MASTERMDREADY',
    'SLEEP_MASTERUPGRADED',
    'SLEEP_MSDBSTARTUP',
    'SLEEP_SYSTEMTASK',
    'SLEEP_TASK',
    'SLEEP_TEMPDBSTARTUP',
    'SNI_HTTP_ACCEPT',
    'SP_SERVER_DIAGNOSTICS_SLEEP',
    'SQLTRACE_BUFFER_FLUSH',
    'SQLTRACE_INCREMENTAL_FLUSH_SLEEP',
    'SQLTRACE_WAIT_ENTRIES',
    'WAIT_FOR_RESULTS',
    'WAITFOR',
    'WAITFOR_TASKSHUTDOWN',
    'XE_DISPATCHER_JOIN',
    'XE_DISPATCHER_WAIT',
    'XE_TIMER_EVENT'
)
AND wait_time_ms > 0
ORDER BY wait_time_ms DESC;
"@

            $waitRows = Invoke-DbaQuery `
                -SqlInstance $TargetInstance `
                -SqlCredential $SqlCredential `
                -Database master `
                -Query $waitStatsQuery `
                -QueryTimeout $QueryTimeout

            foreach ($row in $waitRows) {
                $captureTime = ([datetime]$row.CaptureTime).ToString("yyyy-MM-dd HH:mm:ss")
                $waitType = [string]$row.wait_type
                $safeWaitType = $waitType.Replace("'", "''")

                $metricRows = @(
                    @{ CounterName = "WaitingTasksCount"; MetricValue = [decimal]$row.waiting_tasks_count; Unit = "count" },
                    @{ CounterName = "WaitTimeMs"; MetricValue = [decimal]$row.wait_time_ms; Unit = "ms" },
                    @{ CounterName = "SignalWaitTimeMs"; MetricValue = [decimal]$row.signal_wait_time_ms; Unit = "ms" },
                    @{ CounterName = "ResourceWaitTimeMs"; MetricValue = [decimal]$row.ResourceWaitTimeMs; Unit = "ms" },
                    @{ CounterName = "MaxWaitTimeMs"; MetricValue = [decimal]$row.max_wait_time_ms; Unit = "ms" }
                )

                foreach ($metric in $metricRows) {
                    $counterName = $metric.CounterName.Replace("'", "''")
                    $unit = $metric.Unit.Replace("'", "''")
                    $metricValue = [decimal]$metric.MetricValue

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
    NULL,
    'SQLWaitStats',
    '$counterName',
    N'$safeWaitType',
    'WaitStats',
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
            }

            Complete-CollectionRun `
                -CentralSqlInstance $CentralSqlInstance `
                -CentralDatabase $CentralDatabase `
                -SqlCredential $SqlCredential `
                -CollectionRunId $CollectionRunId `
                -Status "Success" `
                -RowsCollected $RowsCollected

            Write-Info ("Completed {0}. Rows collected: {1}" -f $TargetInstance, $RowsCollected)
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

    Write-Info "Collector finished"
}
catch {
    Write-Fail $_.Exception.Message
    throw
}
