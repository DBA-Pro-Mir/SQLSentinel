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

    $QueryTimeout = 10
    $MinElapsedTimeMs = 30000
    $MinCpuTimeMs = 10000
    $MinLogicalReads = 100000
    $MinPhysicalReads = 10000
    $MinWrites = 10000
    $MinWaitTimeMs = 10000
    $MaximumRequests = 50

    if ($null -ne $config.Collectors -and $null -ne $config.Collectors.ActiveRequests) {
        $activeRequestConfig = $config.Collectors.ActiveRequests

        if ($activeRequestConfig.PSObject.Properties.Name -contains "QueryTimeoutSeconds") { $QueryTimeout = [int]$activeRequestConfig.QueryTimeoutSeconds }
        if ($activeRequestConfig.PSObject.Properties.Name -contains "MinElapsedTimeMs") { $MinElapsedTimeMs = [int]$activeRequestConfig.MinElapsedTimeMs }
        if ($activeRequestConfig.PSObject.Properties.Name -contains "MinCpuTimeMs") { $MinCpuTimeMs = [int]$activeRequestConfig.MinCpuTimeMs }
        if ($activeRequestConfig.PSObject.Properties.Name -contains "MinLogicalReads") { $MinLogicalReads = [int]$activeRequestConfig.MinLogicalReads }
        if ($activeRequestConfig.PSObject.Properties.Name -contains "MinPhysicalReads") { $MinPhysicalReads = [int]$activeRequestConfig.MinPhysicalReads }
        if ($activeRequestConfig.PSObject.Properties.Name -contains "MinWrites") { $MinWrites = [int]$activeRequestConfig.MinWrites }
        if ($activeRequestConfig.PSObject.Properties.Name -contains "MinWaitTimeMs") { $MinWaitTimeMs = [int]$activeRequestConfig.MinWaitTimeMs }
        if ($activeRequestConfig.PSObject.Properties.Name -contains "MaximumRequests") { $MaximumRequests = [int]$activeRequestConfig.MaximumRequests }
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

        Write-Info "Collecting active request metrics from $TargetInstance"

        try {
            $CollectionRunId = Start-CollectionRun `
                -CentralSqlInstance $CentralSqlInstance `
                -CentralDatabase $CentralDatabase `
                -SqlCredential $SqlCredential `
                -InstanceId $InstanceId `
                -CollectorName $CollectorName

            $requestQuery = @"
WITH ActiveRequests AS
(
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
    FROM sys.dm_exec_requests AS r
    INNER JOIN sys.dm_exec_sessions AS s
        ON r.session_id = s.session_id
    OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS st
    WHERE s.is_user_process = 1
      AND ISNULL(s.program_name, '') NOT LIKE '%dbatools%'
      AND ISNULL(s.program_name, '') NOT LIKE '%PowerShell%'
      AND ISNULL(s.login_name, '') <> 'sqlsentinel'
)
SELECT
    SYSDATETIME() AS CaptureTime,
    ActiveRequestCount = COUNT_BIG(1),
    LongRunningRequestCount = SUM(CASE WHEN total_elapsed_time >= $MinElapsedTimeMs THEN 1 ELSE 0 END),
    HighCpuRequestCount = SUM(CASE WHEN cpu_time >= $MinCpuTimeMs THEN 1 ELSE 0 END),
    HighLogicalReadRequestCount = SUM(CASE WHEN logical_reads >= $MinLogicalReads THEN 1 ELSE 0 END),
    HighPhysicalReadRequestCount = SUM(CASE WHEN reads >= $MinPhysicalReads THEN 1 ELSE 0 END),
    HighWriteRequestCount = SUM(CASE WHEN writes >= $MinWrites THEN 1 ELSE 0 END),
    WaitingRequestCount = SUM(CASE WHEN wait_time >= $MinWaitTimeMs OR wait_type IS NOT NULL THEN 1 ELSE 0 END),
    BlockedRequestCount = SUM(CASE WHEN blocking_session_id <> 0 THEN 1 ELSE 0 END),
    MaxElapsedSeconds = ISNULL(MAX(CAST(total_elapsed_time AS decimal(18,2))) / 1000.0, 0),
    TotalCpuMs = ISNULL(SUM(CAST(cpu_time AS bigint)), 0),
    TotalLogicalReads = ISNULL(SUM(CAST(logical_reads AS bigint)), 0),
    TotalPhysicalReads = ISNULL(SUM(CAST(reads AS bigint)), 0),
    TotalWrites = ISNULL(SUM(CAST(writes AS bigint)), 0)
FROM ActiveRequests;

SELECT TOP ($MaximumRequests)
    SYSDATETIME() AS CaptureTime,
    session_id,
    DatabaseName,
    LoginName,
    HostName,
    ProgramName,
    status,
    command,
    wait_type,
    wait_time,
    blocking_session_id,
    cpu_time,
    total_elapsed_time,
    logical_reads,
    reads,
    writes,
    percent_complete,
    SqlText
FROM ActiveRequests
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
    total_elapsed_time DESC,
    logical_reads DESC,
    wait_time DESC;
"@

            $requestResults = Invoke-DbaQuery `
                -SqlInstance $TargetInstance `
                -SqlCredential $SqlCredential `
                -Database master `
                -Query $requestQuery `
                -As DataSet `
                -QueryTimeout $QueryTimeout

            $captureTime = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

            if ($requestResults.Tables.Count -gt 0 -and $requestResults.Tables[0].Rows.Count -gt 0) {
                $summary = $requestResults.Tables[0].Rows[0]

                $summaryMetrics = @(
                    @{ CounterName = "ActiveRequestCount"; Value = [decimal]$summary.ActiveRequestCount; Unit = "count" },
                    @{ CounterName = "LongRunningRequestCount"; Value = [decimal]$summary.LongRunningRequestCount; Unit = "count" },
                    @{ CounterName = "HighCpuRequestCount"; Value = [decimal]$summary.HighCpuRequestCount; Unit = "count" },
                    @{ CounterName = "HighLogicalReadRequestCount"; Value = [decimal]$summary.HighLogicalReadRequestCount; Unit = "count" },
                    @{ CounterName = "HighPhysicalReadRequestCount"; Value = [decimal]$summary.HighPhysicalReadRequestCount; Unit = "count" },
                    @{ CounterName = "HighWriteRequestCount"; Value = [decimal]$summary.HighWriteRequestCount; Unit = "count" },
                    @{ CounterName = "WaitingRequestCount"; Value = [decimal]$summary.WaitingRequestCount; Unit = "count" },
                    @{ CounterName = "BlockedRequestCount"; Value = [decimal]$summary.BlockedRequestCount; Unit = "count" },
                    @{ CounterName = "MaxElapsedSeconds"; Value = [decimal]$summary.MaxElapsedSeconds; Unit = "sec" },
                    @{ CounterName = "TotalCpuMs"; Value = [decimal]$summary.TotalCpuMs; Unit = "ms" },
                    @{ CounterName = "TotalLogicalReads"; Value = [decimal]$summary.TotalLogicalReads; Unit = "count" },
                    @{ CounterName = "TotalPhysicalReads"; Value = [decimal]$summary.TotalPhysicalReads; Unit = "count" },
                    @{ CounterName = "TotalWrites"; Value = [decimal]$summary.TotalWrites; Unit = "count" }
                )

                foreach ($metric in $summaryMetrics) {
                    $counterName = $metric.CounterName.Replace("'", "''")

                    $insertSummary = @"
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
    N'ActiveRequestSummary',
    N'$counterName',
    NULL,
    'ActiveRequest',
    $($metric.Value),
    'Gauge',
    '$($metric.Unit)',
    '$CollectorName'
);
"@

                    Invoke-DbaQuery `
                        -SqlInstance $CentralSqlInstance `
                        -SqlCredential $SqlCredential `
                        -Database $CentralDatabase `
                        -Query $insertSummary `
                        -QueryTimeout $QueryTimeout | Out-Null

                    $RowsCollected++
                }
            }

            if ($requestResults.Tables.Count -gt 1) {
                foreach ($detail in $requestResults.Tables[1].Rows) {
                    $safeDatabaseName = if ([string]::IsNullOrWhiteSpace([string]$detail.DatabaseName)) { "(unknown)" } else { [string]$detail.DatabaseName }
                    $safeLoginName = if ([string]::IsNullOrWhiteSpace([string]$detail.LoginName)) { "(unknown)" } else { [string]$detail.LoginName }
                    $safeHostName = if ([string]::IsNullOrWhiteSpace([string]$detail.HostName)) { "(unknown)" } else { [string]$detail.HostName }
                    $safeProgramName = if ([string]::IsNullOrWhiteSpace([string]$detail.ProgramName)) { "(unknown)" } else { [string]$detail.ProgramName }
                    $safeStatus = if ([string]::IsNullOrWhiteSpace([string]$detail.status)) { "(unknown)" } else { [string]$detail.status }
                    $safeCommand = if ([string]::IsNullOrWhiteSpace([string]$detail.command)) { "(unknown)" } else { [string]$detail.command }
                    $safeWaitType = if ([string]::IsNullOrWhiteSpace([string]$detail.wait_type)) { "(none)" } else { [string]$detail.wait_type }
                    $safeSqlText = if ([string]::IsNullOrWhiteSpace([string]$detail.SqlText)) { "(unavailable)" } else { [string]$detail.SqlText }

                    $detailText = @"
SessionId: $($detail.session_id)
DatabaseName: $safeDatabaseName
LoginName: $safeLoginName
HostName: $safeHostName
ProgramName: $safeProgramName
Status: $safeStatus
Command: $safeCommand
WaitType: $safeWaitType
WaitSeconds: $([math]::Round(([decimal]$detail.wait_time / 1000.0), 3))
BlockingSessionId: $($detail.blocking_session_id)
CpuTimeMs: $($detail.cpu_time)
ElapsedTimeMs: $($detail.total_elapsed_time)
LogicalReads: $($detail.logical_reads)
Reads: $($detail.reads)
Writes: $($detail.writes)
PercentComplete: $($detail.percent_complete)
SQL text: $safeSqlText
"@

                    $safeDetails = $detailText.Replace("'", "''")

                    $insertDetail = @"
INSERT INTO dbo.MetricTextSnapshot
(
    InstanceId,
    CaptureTime,
    MetricCategory,
    DetailType,
    Severity,
    Details,
    NumericValue1,
    NumericValue2,
    SourceCollector
)
VALUES
(
    $InstanceId,
    '$captureTime',
    'ActiveRequest',
    'ActiveRequestDetail',
    'Warning',
    N'$safeDetails',
    $( [decimal]$detail.total_elapsed_time / 1000.0 ),
    $( [decimal]$detail.cpu_time ),
    '$CollectorName'
);
"@

                    Invoke-DbaQuery `
                        -SqlInstance $CentralSqlInstance `
                        -SqlCredential $SqlCredential `
                        -Database $CentralDatabase `
                        -Query $insertDetail `
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
