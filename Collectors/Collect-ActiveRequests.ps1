<#
===============================================================================
 SQLSentinel - Active Request Collector
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

$CollectorName = "Collect-ActiveRequests"

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
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

    Import-Module dbatools

    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

    $CentralSqlInstance = $config.CentralSqlInstance
    $CentralDatabase = $config.CentralDatabase

    $QueryTimeout = 10
    $MinElapsedTimeMs = 30000
    $MinCpuTimeMs = 10000
    $MinLogicalReads = 100000
    $MinPhysicalReads = 10000
    $MinWrites = 10000
    $MinWaitTimeMs = 10000
    $MaximumRequests = 50

    if ($null -ne $config.Collectors -and
        $null -ne $config.Collectors.ActiveRequests) {

        $activeRequestConfig = $config.Collectors.ActiveRequests

        if ($activeRequestConfig.PSObject.Properties.Name -contains "QueryTimeoutSeconds") {
            $QueryTimeout = [int]$activeRequestConfig.QueryTimeoutSeconds
        }

        if ($activeRequestConfig.PSObject.Properties.Name -contains "MinElapsedTimeMs") {
            $MinElapsedTimeMs = [int]$activeRequestConfig.MinElapsedTimeMs
        }

        if ($activeRequestConfig.PSObject.Properties.Name -contains "MinCpuTimeMs") {
            $MinCpuTimeMs = [int]$activeRequestConfig.MinCpuTimeMs
        }

        if ($activeRequestConfig.PSObject.Properties.Name -contains "MinLogicalReads") {
            $MinLogicalReads = [int]$activeRequestConfig.MinLogicalReads
        }

        if ($activeRequestConfig.PSObject.Properties.Name -contains "MinPhysicalReads") {
            $MinPhysicalReads = [int]$activeRequestConfig.MinPhysicalReads
        }

        if ($activeRequestConfig.PSObject.Properties.Name -contains "MinWrites") {
            $MinWrites = [int]$activeRequestConfig.MinWrites
        }

        if ($activeRequestConfig.PSObject.Properties.Name -contains "MinWaitTimeMs") {
            $MinWaitTimeMs = [int]$activeRequestConfig.MinWaitTimeMs
        }

        if ($activeRequestConfig.PSObject.Properties.Name -contains "MaximumRequests") {
            $MaximumRequests = [int]$activeRequestConfig.MaximumRequests
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
        -Query "
SELECT
    InstanceId,
    InstanceName
FROM dbo.MonitoredInstances
WHERE IsEnabled = 1;
" `
        -QueryTimeout 30

    foreach ($instance in $instances) {

        $InstanceId = [int]$instance.InstanceId
        $TargetInstance = [string]$instance.InstanceName
        $RowsCollected = 0
        $CollectionRunId = $null

        Write-Info "Collecting active request metrics from $TargetInstance"

        try {

            $CollectionRunId = Start-CollectionRun `
                -CentralSqlInstance $CentralSqlInstance `
                -CentralDatabase $CentralDatabase `
                -SqlCredential $SqlCredential `
                -InstanceId $InstanceId `
                -CollectorName $CollectorName

            $query = @"
IF OBJECT_ID('tempdb..#ActiveRequests') IS NOT NULL
    DROP TABLE #ActiveRequests;

SELECT
    r.session_id,
    DatabaseName = DB_NAME(r.database_id),
    LoginName = s.login_name,
    HostName = s.host_name,
    ProgramName = s.program_name,
    r.status,
    r.command,
    r.wait_type,
    wait_time = ISNULL(r.wait_time, 0),
    blocking_session_id = ISNULL(r.blocking_session_id, 0),
    cpu_time = ISNULL(r.cpu_time, 0),
    total_elapsed_time = ISNULL(r.total_elapsed_time, 0),
    logical_reads = ISNULL(r.logical_reads, 0),
    reads = ISNULL(r.reads, 0),
    writes = ISNULL(r.writes, 0),
    percent_complete = ISNULL(r.percent_complete, 0),
    SqlText = LEFT(CAST(st.text AS nvarchar(max)), 4000)
INTO #ActiveRequests
FROM sys.dm_exec_requests AS r
INNER JOIN sys.dm_exec_sessions AS s
    ON r.session_id = s.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS st
WHERE s.is_user_process = 1
  AND ISNULL(s.program_name, '') NOT LIKE '%dbatools%'
  AND ISNULL(s.program_name, '') NOT LIKE '%PowerShell%'
  AND ISNULL(s.login_name, '') <> 'sqlsentinel';

SELECT
    ActiveRequestCount = COUNT_BIG(1),
    LongRunningRequestCount = ISNULL(SUM(CASE WHEN total_elapsed_time >= $MinElapsedTimeMs THEN 1 ELSE 0 END),0),
    HighCpuRequestCount = ISNULL(SUM(CASE WHEN cpu_time >= $MinCpuTimeMs THEN 1 ELSE 0 END),0),
    HighLogicalReadRequestCount = ISNULL(SUM(CASE WHEN logical_reads >= $MinLogicalReads THEN 1 ELSE 0 END),0),
    HighPhysicalReadRequestCount = ISNULL(SUM(CASE WHEN reads >= $MinPhysicalReads THEN 1 ELSE 0 END),0),
    HighWriteRequestCount = ISNULL(SUM(CASE WHEN writes >= $MinWrites THEN 1 ELSE 0 END),0),
    WaitingRequestCount = ISNULL(SUM(CASE WHEN wait_time >= $MinWaitTimeMs THEN 1 ELSE 0 END),0),
    BlockedRequestCount = ISNULL(SUM(CASE WHEN blocking_session_id <> 0 THEN 1 ELSE 0 END),0),
    MaxElapsedSeconds = ISNULL(MAX(CAST(total_elapsed_time AS decimal(18,2))) / 1000.0,0),
    TotalCpuMs = ISNULL(SUM(cpu_time),0),
    TotalLogicalReads = ISNULL(SUM(logical_reads),0),
    TotalPhysicalReads = ISNULL(SUM(reads),0),
    TotalWrites = ISNULL(SUM(writes),0)
FROM #ActiveRequests;

SELECT TOP ($MaximumRequests)
    *
FROM #ActiveRequests
WHERE
    total_elapsed_time >= $MinElapsedTimeMs
    OR cpu_time >= $MinCpuTimeMs
    OR logical_reads >= $MinLogicalReads
    OR reads >= $MinPhysicalReads
    OR writes >= $MinWrites
    OR wait_time >= $MinWaitTimeMs
    OR blocking_session_id <> 0
ORDER BY
    cpu_time DESC,
    total_elapsed_time DESC;

DROP TABLE #ActiveRequests;
"@

            $results = Invoke-DbaQuery `
                -SqlInstance $TargetInstance `
                -SqlCredential $SqlCredential `
                -Database master `
                -Query $query `
                -As DataSet `
                -QueryTimeout $QueryTimeout

            $summary = $results.Tables[0].Rows[0]

            $summaryMetrics = @(
                @{ Name = "ActiveRequestCount"; Value = $summary.ActiveRequestCount; Unit = "count" },
                @{ Name = "LongRunningRequestCount"; Value = $summary.LongRunningRequestCount; Unit = "count" },
                @{ Name = "HighCpuRequestCount"; Value = $summary.HighCpuRequestCount; Unit = "count" },
                @{ Name = "HighLogicalReadRequestCount"; Value = $summary.HighLogicalReadRequestCount; Unit = "count" },
                @{ Name = "HighPhysicalReadRequestCount"; Value = $summary.HighPhysicalReadRequestCount; Unit = "count" },
                @{ Name = "HighWriteRequestCount"; Value = $summary.HighWriteRequestCount; Unit = "count" },
                @{ Name = "WaitingRequestCount"; Value = $summary.WaitingRequestCount; Unit = "count" },
                @{ Name = "BlockedRequestCount"; Value = $summary.BlockedRequestCount; Unit = "count" },
                @{ Name = "MaxElapsedSeconds"; Value = $summary.MaxElapsedSeconds; Unit = "sec" },
                @{ Name = "TotalCpuMs"; Value = $summary.TotalCpuMs; Unit = "ms" },
                @{ Name = "TotalLogicalReads"; Value = $summary.TotalLogicalReads; Unit = "count" },
                @{ Name = "TotalPhysicalReads"; Value = $summary.TotalPhysicalReads; Unit = "count" },
                @{ Name = "TotalWrites"; Value = $summary.TotalWrites; Unit = "count" }
            )

            foreach ($metric in $summaryMetrics) {

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
    SYSDATETIME(),
    NULL,
    'ActiveRequestSummary',
    '$($metric.Name)',
    NULL,
    'ActiveRequest',
    $($metric.Value),
    'Gauge',
    '$($metric.Unit)',
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

            Write-Info "Completed $TargetInstance ($RowsCollected rows)"
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