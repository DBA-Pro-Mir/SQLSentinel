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

function Get-SafeString {
    param($Value, [string]$Default = "(unknown)")

    if ($null -eq $Value -or $Value -is [System.DBNull]) {
        return $Default
    }

    $text = [string]$Value

    if ([string]::IsNullOrWhiteSpace($text)) {
        return $Default
    }

    return $text
}

function Get-SafeDecimal {
    param($Value, [decimal]$Default = 0)

    if ($null -eq $Value -or $Value -is [System.DBNull]) {
        return $Default
    }

    return [decimal]$Value
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
    $MaximumAttributionRows = 25
    $MaximumRepeatedQueryRows = 25

    if ($null -ne $config.Collectors -and
        $config.Collectors.PSObject.Properties.Name -contains "ActiveRequests") {

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

        if ($activeRequestConfig.PSObject.Properties.Name -contains "MaximumAttributionRows") {
            $MaximumAttributionRows = [int]$activeRequestConfig.MaximumAttributionRows
        }

        if ($activeRequestConfig.PSObject.Properties.Name -contains "MaximumRepeatedQueryRows") {
            $MaximumRepeatedQueryRows = [int]$activeRequestConfig.MaximumRepeatedQueryRows
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
    SqlText = LEFT(REPLACE(REPLACE(CAST(st.text AS nvarchar(max)), CHAR(13), ' '), CHAR(10), ' '), 4000),
    QuerySignature = CONVERT(varchar(40), HASHBYTES('SHA1', CONVERT(varbinary(max), LEFT(REPLACE(REPLACE(CAST(st.text AS nvarchar(max)), CHAR(13), ' '), CHAR(10), ' '), 4000))), 2)
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
    LongRunningRequestCount = ISNULL(SUM(CASE WHEN total_elapsed_time >= $MinElapsedTimeMs THEN 1 ELSE 0 END), 0),
    HighCpuRequestCount = ISNULL(SUM(CASE WHEN cpu_time >= $MinCpuTimeMs THEN 1 ELSE 0 END), 0),
    HighLogicalReadRequestCount = ISNULL(SUM(CASE WHEN logical_reads >= $MinLogicalReads THEN 1 ELSE 0 END), 0),
    HighPhysicalReadRequestCount = ISNULL(SUM(CASE WHEN reads >= $MinPhysicalReads THEN 1 ELSE 0 END), 0),
    HighWriteRequestCount = ISNULL(SUM(CASE WHEN writes >= $MinWrites THEN 1 ELSE 0 END), 0),
    WaitingRequestCount = ISNULL(SUM(CASE WHEN wait_time >= $MinWaitTimeMs OR wait_type IS NOT NULL THEN 1 ELSE 0 END), 0),
    BlockedRequestCount = ISNULL(SUM(CASE WHEN blocking_session_id <> 0 THEN 1 ELSE 0 END), 0),
    MaxElapsedSeconds = ISNULL(MAX(CAST(total_elapsed_time AS decimal(18,2))) / 1000.0, 0),
    TotalCpuMs = ISNULL(SUM(CAST(cpu_time AS bigint)), 0),
    TotalLogicalReads = ISNULL(SUM(CAST(logical_reads AS bigint)), 0),
    TotalPhysicalReads = ISNULL(SUM(CAST(reads AS bigint)), 0),
    TotalWrites = ISNULL(SUM(CAST(writes AS bigint)), 0)
FROM #ActiveRequests;

SELECT TOP ($MaximumRequests)
    DetailType = 'ActiveRequestDetail',
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
    QuerySignature,
    SqlText
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
    total_elapsed_time DESC,
    logical_reads DESC,
    wait_time DESC;

SELECT TOP ($MaximumAttributionRows)
    DetailType = 'ActiveRequestByDatabase',
    GroupValue = COALESCE(NULLIF(DatabaseName, ''), '(unknown)'),
    ActiveRequestCount = COUNT_BIG(1),
    TotalCpuMs = ISNULL(SUM(CAST(cpu_time AS bigint)), 0),
    TotalElapsedMs = ISNULL(SUM(CAST(total_elapsed_time AS bigint)), 0),
    TotalLogicalReads = ISNULL(SUM(CAST(logical_reads AS bigint)), 0),
    TotalReads = ISNULL(SUM(CAST(reads AS bigint)), 0),
    TotalWrites = ISNULL(SUM(CAST(writes AS bigint)), 0),
    BlockedRequestCount = ISNULL(SUM(CASE WHEN blocking_session_id <> 0 THEN 1 ELSE 0 END), 0),
    SampleWaitType = MAX(wait_type),
    SampleDatabaseName = MAX(DatabaseName),
    SampleHostName = MAX(HostName),
    SampleProgramName = MAX(ProgramName)
FROM #ActiveRequests
GROUP BY COALESCE(NULLIF(DatabaseName, ''), '(unknown)')
ORDER BY
    ISNULL(SUM(CAST(cpu_time AS bigint)), 0) DESC,
    ISNULL(SUM(CAST(total_elapsed_time AS bigint)), 0) DESC,
    ISNULL(SUM(CAST(logical_reads AS bigint)), 0) DESC;

SELECT TOP ($MaximumAttributionRows)
    DetailType = 'ActiveRequestByHost',
    GroupValue = COALESCE(NULLIF(HostName, ''), '(unknown)'),
    ActiveRequestCount = COUNT_BIG(1),
    TotalCpuMs = ISNULL(SUM(CAST(cpu_time AS bigint)), 0),
    TotalElapsedMs = ISNULL(SUM(CAST(total_elapsed_time AS bigint)), 0),
    TotalLogicalReads = ISNULL(SUM(CAST(logical_reads AS bigint)), 0),
    TotalReads = ISNULL(SUM(CAST(reads AS bigint)), 0),
    TotalWrites = ISNULL(SUM(CAST(writes AS bigint)), 0),
    BlockedRequestCount = ISNULL(SUM(CASE WHEN blocking_session_id <> 0 THEN 1 ELSE 0 END), 0),
    SampleWaitType = MAX(wait_type),
    SampleDatabaseName = MAX(DatabaseName),
    SampleHostName = MAX(HostName),
    SampleProgramName = MAX(ProgramName)
FROM #ActiveRequests
GROUP BY COALESCE(NULLIF(HostName, ''), '(unknown)')
ORDER BY
    ISNULL(SUM(CAST(cpu_time AS bigint)), 0) DESC,
    ISNULL(SUM(CAST(total_elapsed_time AS bigint)), 0) DESC,
    ISNULL(SUM(CAST(logical_reads AS bigint)), 0) DESC;

SELECT TOP ($MaximumAttributionRows)
    DetailType = 'ActiveRequestByProgram',
    GroupValue = COALESCE(NULLIF(ProgramName, ''), '(unknown)'),
    ActiveRequestCount = COUNT_BIG(1),
    TotalCpuMs = ISNULL(SUM(CAST(cpu_time AS bigint)), 0),
    TotalElapsedMs = ISNULL(SUM(CAST(total_elapsed_time AS bigint)), 0),
    TotalLogicalReads = ISNULL(SUM(CAST(logical_reads AS bigint)), 0),
    TotalReads = ISNULL(SUM(CAST(reads AS bigint)), 0),
    TotalWrites = ISNULL(SUM(CAST(writes AS bigint)), 0),
    BlockedRequestCount = ISNULL(SUM(CASE WHEN blocking_session_id <> 0 THEN 1 ELSE 0 END), 0),
    SampleWaitType = MAX(wait_type),
    SampleDatabaseName = MAX(DatabaseName),
    SampleHostName = MAX(HostName),
    SampleProgramName = MAX(ProgramName)
FROM #ActiveRequests
GROUP BY COALESCE(NULLIF(ProgramName, ''), '(unknown)')
ORDER BY
    ISNULL(SUM(CAST(cpu_time AS bigint)), 0) DESC,
    ISNULL(SUM(CAST(total_elapsed_time AS bigint)), 0) DESC,
    ISNULL(SUM(CAST(logical_reads AS bigint)), 0) DESC;

SELECT TOP ($MaximumAttributionRows)
    DetailType = 'ActiveRequestByLogin',
    GroupValue = COALESCE(NULLIF(LoginName, ''), '(unknown)'),
    ActiveRequestCount = COUNT_BIG(1),
    TotalCpuMs = ISNULL(SUM(CAST(cpu_time AS bigint)), 0),
    TotalElapsedMs = ISNULL(SUM(CAST(total_elapsed_time AS bigint)), 0),
    TotalLogicalReads = ISNULL(SUM(CAST(logical_reads AS bigint)), 0),
    TotalReads = ISNULL(SUM(CAST(reads AS bigint)), 0),
    TotalWrites = ISNULL(SUM(CAST(writes AS bigint)), 0),
    BlockedRequestCount = ISNULL(SUM(CASE WHEN blocking_session_id <> 0 THEN 1 ELSE 0 END), 0),
    SampleWaitType = MAX(wait_type),
    SampleDatabaseName = MAX(DatabaseName),
    SampleHostName = MAX(HostName),
    SampleProgramName = MAX(ProgramName)
FROM #ActiveRequests
GROUP BY COALESCE(NULLIF(LoginName, ''), '(unknown)')
ORDER BY
    ISNULL(SUM(CAST(cpu_time AS bigint)), 0) DESC,
    ISNULL(SUM(CAST(total_elapsed_time AS bigint)), 0) DESC,
    ISNULL(SUM(CAST(logical_reads AS bigint)), 0) DESC;

SELECT TOP ($MaximumRepeatedQueryRows)
    DetailType = 'RepeatedActiveQuery',
    QuerySignature,
    ActiveRequestCount = COUNT_BIG(1),
    TotalCpuMs = ISNULL(SUM(CAST(cpu_time AS bigint)), 0),
    TotalElapsedMs = ISNULL(SUM(CAST(total_elapsed_time AS bigint)), 0),
    TotalLogicalReads = ISNULL(SUM(CAST(logical_reads AS bigint)), 0),
    TotalReads = ISNULL(SUM(CAST(reads AS bigint)), 0),
    TotalWrites = ISNULL(SUM(CAST(writes AS bigint)), 0),
    SampleDatabaseName = MAX(DatabaseName),
    SampleLoginName = MAX(LoginName),
    SampleHostName = MAX(HostName),
    SampleProgramName = MAX(ProgramName),
    SampleSqlText = MAX(SqlText)
FROM #ActiveRequests
WHERE QuerySignature IS NOT NULL
GROUP BY QuerySignature
HAVING COUNT_BIG(1) > 1
ORDER BY
    COUNT_BIG(1) DESC,
    ISNULL(SUM(CAST(cpu_time AS bigint)), 0) DESC,
    ISNULL(SUM(CAST(total_elapsed_time AS bigint)), 0) DESC;

DROP TABLE #ActiveRequests;
"@

            $results = Invoke-DbaQuery `
                -SqlInstance $TargetInstance `
                -SqlCredential $SqlCredential `
                -Database master `
                -Query $query `
                -As DataSet `
                -QueryTimeout $QueryTimeout

            $captureTime = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

            if ($results.Tables.Count -gt 0 -and $results.Tables[0].Rows.Count -gt 0) {

                $summary = $results.Tables[0].Rows[0]

                $summaryMetrics = @(
                    @{ Name = "ActiveRequestCount"; Value = (Get-SafeDecimal $summary.ActiveRequestCount); Unit = "count" },
                    @{ Name = "LongRunningRequestCount"; Value = (Get-SafeDecimal $summary.LongRunningRequestCount); Unit = "count" },
                    @{ Name = "HighCpuRequestCount"; Value = (Get-SafeDecimal $summary.HighCpuRequestCount); Unit = "count" },
                    @{ Name = "HighLogicalReadRequestCount"; Value = (Get-SafeDecimal $summary.HighLogicalReadRequestCount); Unit = "count" },
                    @{ Name = "HighPhysicalReadRequestCount"; Value = (Get-SafeDecimal $summary.HighPhysicalReadRequestCount); Unit = "count" },
                    @{ Name = "HighWriteRequestCount"; Value = (Get-SafeDecimal $summary.HighWriteRequestCount); Unit = "count" },
                    @{ Name = "WaitingRequestCount"; Value = (Get-SafeDecimal $summary.WaitingRequestCount); Unit = "count" },
                    @{ Name = "BlockedRequestCount"; Value = (Get-SafeDecimal $summary.BlockedRequestCount); Unit = "count" },
                    @{ Name = "MaxElapsedSeconds"; Value = (Get-SafeDecimal $summary.MaxElapsedSeconds); Unit = "sec" },
                    @{ Name = "TotalCpuMs"; Value = (Get-SafeDecimal $summary.TotalCpuMs); Unit = "ms" },
                    @{ Name = "TotalLogicalReads"; Value = (Get-SafeDecimal $summary.TotalLogicalReads); Unit = "count" },
                    @{ Name = "TotalPhysicalReads"; Value = (Get-SafeDecimal $summary.TotalPhysicalReads); Unit = "count" },
                    @{ Name = "TotalWrites"; Value = (Get-SafeDecimal $summary.TotalWrites); Unit = "count" }
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
    '$captureTime',
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
            }

            if ($results.Tables.Count -gt 1) {
                foreach ($detail in $results.Tables[1].Rows) {

                    $safeDatabaseName = (Get-SafeString $detail.DatabaseName).Replace("'", "''")
                    $safeLoginName = (Get-SafeString $detail.LoginName).Replace("'", "''")
                    $safeHostName = (Get-SafeString $detail.HostName).Replace("'", "''")
                    $safeProgramName = (Get-SafeString $detail.ProgramName).Replace("'", "''")
                    $safeStatus = (Get-SafeString $detail.status).Replace("'", "''")
                    $safeCommand = (Get-SafeString $detail.command).Replace("'", "''")
                    $safeWaitType = (Get-SafeString $detail.wait_type "(none)").Replace("'", "''")
                    $safeSqlText = (Get-SafeString $detail.SqlText "(unavailable)").Replace("'", "''")
                    $safeQuerySignature = (Get-SafeString $detail.QuerySignature "(none)").Replace("'", "''")

                    $detailText = @"
DetailType: ActiveRequestDetail
SessionId: $($detail.session_id)
DatabaseName: $safeDatabaseName
LoginName: $safeLoginName
HostName: $safeHostName
ProgramName: $safeProgramName
Status: $safeStatus
Command: $safeCommand
WaitType: $safeWaitType
WaitSeconds: $([math]::Round((Get-SafeDecimal $detail.wait_time) / 1000.0, 3))
BlockingSessionId: $($detail.blocking_session_id)
CpuTimeMs: $($detail.cpu_time)
ElapsedTimeMs: $($detail.total_elapsed_time)
LogicalReads: $($detail.logical_reads)
Reads: $($detail.reads)
Writes: $($detail.writes)
PercentComplete: $($detail.percent_complete)
QuerySignature: $safeQuerySignature
SQL text: $safeSqlText
"@

                    $safeDetails = $detailText.Replace("'", "''")

                    Invoke-DbaQuery `
                        -SqlInstance $CentralSqlInstance `
                        -SqlCredential $SqlCredential `
                        -Database $CentralDatabase `
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
    'ActiveRequest',
    'ActiveRequestDetail',
    'Warning',
    $([decimal]((Get-SafeDecimal $detail.total_elapsed_time) / 1000.0)),
    $(Get-SafeDecimal $detail.cpu_time),
    N'$safeDetails',
    '$CollectorName'
);
"@ `
                        -QueryTimeout $QueryTimeout | Out-Null

                    $RowsCollected++
                }
            }

            for ($tableIndex = 2; $tableIndex -le 5; $tableIndex++) {
                if ($results.Tables.Count -gt $tableIndex) {
                    foreach ($group in $results.Tables[$tableIndex].Rows) {

                        $detailType = Get-SafeString $group.DetailType
                        $groupValue = (Get-SafeString $group.GroupValue).Replace("'", "''")

                        $detailText = @"
DetailType: $detailType
GroupValue: $groupValue
ActiveRequestCount: $($group.ActiveRequestCount)
TotalCpuMs: $($group.TotalCpuMs)
TotalElapsedMs: $($group.TotalElapsedMs)
TotalLogicalReads: $($group.TotalLogicalReads)
TotalReads: $($group.TotalReads)
TotalWrites: $($group.TotalWrites)
BlockedRequestCount: $($group.BlockedRequestCount)
SampleWaitType: $(Get-SafeString $group.SampleWaitType "(none)")
SampleDatabaseName: $(Get-SafeString $group.SampleDatabaseName "(unknown)")
SampleHostName: $(Get-SafeString $group.SampleHostName "(unknown)")
SampleProgramName: $(Get-SafeString $group.SampleProgramName "(unknown)")
"@

                        $safeDetails = $detailText.Replace("'", "''")
                        $safeDetailType = $detailType.Replace("'", "''")

                        Invoke-DbaQuery `
                            -SqlInstance $CentralSqlInstance `
                            -SqlCredential $SqlCredential `
                            -Database $CentralDatabase `
                            -Query @"
INSERT INTO dbo.MetricTextSnapshot
(
    InstanceId,
    CaptureTime,
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
    'ActiveRequest',
    '$safeDetailType',
    'Info',
    $(Get-SafeDecimal $group.TotalCpuMs),
    $(Get-SafeDecimal $group.TotalElapsedMs),
    N'$safeDetails',
    '$CollectorName'
);
"@ `
                            -QueryTimeout $QueryTimeout | Out-Null

                        $RowsCollected++
                    }
                }
            }

            if ($results.Tables.Count -gt 6) {
                foreach ($repeated in $results.Tables[6].Rows) {

                    $safeDatabaseName = (Get-SafeString $repeated.SampleDatabaseName).Replace("'", "''")
                    $safeLoginName = (Get-SafeString $repeated.SampleLoginName).Replace("'", "''")
                    $safeHostName = (Get-SafeString $repeated.SampleHostName).Replace("'", "''")
                    $safeProgramName = (Get-SafeString $repeated.SampleProgramName).Replace("'", "''")
                    $safeSqlText = (Get-SafeString $repeated.SampleSqlText "(unavailable)").Replace("'", "''")
                    $safeQuerySignature = (Get-SafeString $repeated.QuerySignature "(none)").Replace("'", "''")

                    $detailText = @"
DetailType: RepeatedActiveQuery
QuerySignature: $safeQuerySignature
ActiveRequestCount: $($repeated.ActiveRequestCount)
TotalCpuMs: $($repeated.TotalCpuMs)
TotalElapsedMs: $($repeated.TotalElapsedMs)
TotalLogicalReads: $($repeated.TotalLogicalReads)
TotalReads: $($repeated.TotalReads)
TotalWrites: $($repeated.TotalWrites)
SampleDatabaseName: $safeDatabaseName
SampleLoginName: $safeLoginName
SampleHostName: $safeHostName
SampleProgramName: $safeProgramName
SQL text: $safeSqlText
"@

                    $safeDetails = $detailText.Replace("'", "''")

                    Invoke-DbaQuery `
                        -SqlInstance $CentralSqlInstance `
                        -SqlCredential $SqlCredential `
                        -Database $CentralDatabase `
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
    'ActiveRequest',
    'RepeatedActiveQuery',
    'Warning',
    $(Get-SafeDecimal $repeated.TotalCpuMs),
    $(Get-SafeDecimal $repeated.ActiveRequestCount),
    N'$safeDetails',
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
