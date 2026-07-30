<#
===============================================================================
 SQLSentinel - Query Stats Collector V2
===============================================================================
 Collects a bounded set of expensive cached queries without applying SQL text
 and plan-attribute functions to the entire plan cache.
#>

[CmdletBinding()]
param
(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = ".\Config\SQLSentinel.config.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$CollectorName = "Collect-QueryStats"

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

    if (-not (Get-Module -ListAvailable -Name dbatools)) {
        throw "dbatools module is not installed."
    }

    Import-Module dbatools

    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

    $CentralSqlInstance = $config.CentralSqlInstance
    $CentralDatabase = $config.CentralDatabase

    $QueryTimeout = 120
    $TopQueriesPerCategory = 25
    $LookbackMinutes = 60
    $MaxSqlTextLength = 1000
    $MinimumExecutionCount = 1

    if ($null -ne $config.Collectors -and
        $config.Collectors.PSObject.Properties.Name -contains "QueryStats") {

        $queryStatsConfig = $config.Collectors.QueryStats

        if ($queryStatsConfig.PSObject.Properties.Name -contains "QueryTimeoutSeconds") {
            $QueryTimeout = [int]$queryStatsConfig.QueryTimeoutSeconds
        }

        if ($queryStatsConfig.PSObject.Properties.Name -contains "TopQueriesPerCategory") {
            $TopQueriesPerCategory = [int]$queryStatsConfig.TopQueriesPerCategory
        }

        if ($queryStatsConfig.PSObject.Properties.Name -contains "LookbackMinutes") {
            $LookbackMinutes = [int]$queryStatsConfig.LookbackMinutes
        }

        if ($queryStatsConfig.PSObject.Properties.Name -contains "MaxSqlTextLength") {
            $MaxSqlTextLength = [int]$queryStatsConfig.MaxSqlTextLength
        }

        if ($queryStatsConfig.PSObject.Properties.Name -contains "MinimumExecutionCount") {
            $MinimumExecutionCount = [int]$queryStatsConfig.MinimumExecutionCount
        }
    }

    if ($TopQueriesPerCategory -lt 1) { $TopQueriesPerCategory = 1 }
    if ($TopQueriesPerCategory -gt 100) { $TopQueriesPerCategory = 100 }
    if ($LookbackMinutes -lt 1) { $LookbackMinutes = 60 }
    if ($MaxSqlTextLength -lt 100) { $MaxSqlTextLength = 100 }
    if ($MaxSqlTextLength -gt 4000) { $MaxSqlTextLength = 4000 }
    if ($MinimumExecutionCount -lt 1) { $MinimumExecutionCount = 1 }

    $SqlCredential = $null

    if ($config.SqlCredential.Username -and $config.SqlCredential.Password) {
        $SqlCredential = New-Object System.Management.Automation.PSCredential(
            $config.SqlCredential.Username,
            (ConvertTo-SecureString $config.SqlCredential.Password -AsPlainText -Force)
        )
    }

    Write-Info "Starting $CollectorName"
    Write-Info "Repository: $CentralSqlInstance / $CentralDatabase"
    Write-Info "V2 settings: Top $TopQueriesPerCategory per category; lookback $LookbackMinutes minutes; SQL text $MaxSqlTextLength characters"

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

        Write-Info "Collecting query stats from $TargetInstance"

        try {
            $CollectionRunId = Start-CollectionRun `
                -CentralSqlInstance $CentralSqlInstance `
                -CentralDatabase $CentralDatabase `
                -SqlCredential $SqlCredential `
                -InstanceId $InstanceId `
                -CollectorName $CollectorName

            $queryStatsQuery = @"
SET NOCOUNT ON;
SET LOCK_TIMEOUT 5000;

IF OBJECT_ID('tempdb..#Candidates') IS NOT NULL DROP TABLE #Candidates;
IF OBJECT_ID('tempdb..#CandidateDetails') IS NOT NULL DROP TABLE #CandidateDetails;

CREATE TABLE #Candidates
(
    RankingCategory varchar(30) NOT NULL,
    sql_handle varbinary(64) NOT NULL,
    plan_handle varbinary(64) NOT NULL,
    query_hash binary(8) NULL,
    query_plan_hash binary(8) NULL,
    execution_count bigint NOT NULL,
    creation_time datetime NOT NULL,
    last_execution_time datetime NOT NULL,
    total_worker_time bigint NOT NULL,
    total_elapsed_time bigint NOT NULL,
    total_logical_reads bigint NOT NULL,
    total_physical_reads bigint NOT NULL,
    total_logical_writes bigint NOT NULL
);

INSERT INTO #Candidates
SELECT TOP ($TopQueriesPerCategory)
    'CPU', sql_handle, plan_handle, query_hash, query_plan_hash,
    execution_count, creation_time, last_execution_time,
    total_worker_time, total_elapsed_time, total_logical_reads,
    total_physical_reads, total_logical_writes
FROM sys.dm_exec_query_stats
WHERE last_execution_time >= DATEADD(MINUTE, -$LookbackMinutes, SYSDATETIME())
  AND execution_count >= $MinimumExecutionCount
ORDER BY total_worker_time DESC;

INSERT INTO #Candidates
SELECT TOP ($TopQueriesPerCategory)
    'Duration', sql_handle, plan_handle, query_hash, query_plan_hash,
    execution_count, creation_time, last_execution_time,
    total_worker_time, total_elapsed_time, total_logical_reads,
    total_physical_reads, total_logical_writes
FROM sys.dm_exec_query_stats
WHERE last_execution_time >= DATEADD(MINUTE, -$LookbackMinutes, SYSDATETIME())
  AND execution_count >= $MinimumExecutionCount
ORDER BY total_elapsed_time DESC;

INSERT INTO #Candidates
SELECT TOP ($TopQueriesPerCategory)
    'LogicalReads', sql_handle, plan_handle, query_hash, query_plan_hash,
    execution_count, creation_time, last_execution_time,
    total_worker_time, total_elapsed_time, total_logical_reads,
    total_physical_reads, total_logical_writes
FROM sys.dm_exec_query_stats
WHERE last_execution_time >= DATEADD(MINUTE, -$LookbackMinutes, SYSDATETIME())
  AND execution_count >= $MinimumExecutionCount
ORDER BY total_logical_reads DESC;

INSERT INTO #Candidates
SELECT TOP ($TopQueriesPerCategory)
    'Executions', sql_handle, plan_handle, query_hash, query_plan_hash,
    execution_count, creation_time, last_execution_time,
    total_worker_time, total_elapsed_time, total_logical_reads,
    total_physical_reads, total_logical_writes
FROM sys.dm_exec_query_stats
WHERE last_execution_time >= DATEADD(MINUTE, -$LookbackMinutes, SYSDATETIME())
  AND execution_count >= $MinimumExecutionCount
ORDER BY execution_count DESC;

;WITH Deduplicated AS
(
    SELECT
        c.*,
        rn = ROW_NUMBER() OVER
        (
            PARTITION BY
                c.RankingCategory,
                ISNULL(c.query_hash, 0x0000000000000000),
                ISNULL(c.query_plan_hash, 0x0000000000000000)
            ORDER BY
                c.total_worker_time DESC,
                c.total_elapsed_time DESC,
                c.last_execution_time DESC
        )
    FROM #Candidates c
), Enriched AS
(
    SELECT
        d.RankingCategory,
        DatabaseName = DB_NAME(CONVERT(int, pa.value)),
        d.query_hash,
        d.query_plan_hash,
        d.execution_count,
        d.creation_time,
        d.last_execution_time,
        TotalCpuMs = CONVERT(decimal(19,2), d.total_worker_time / 1000.0),
        AvgCpuMs = CONVERT(decimal(19,2), (d.total_worker_time / 1000.0) / NULLIF(d.execution_count, 0)),
        TotalElapsedMs = CONVERT(decimal(19,2), d.total_elapsed_time / 1000.0),
        AvgElapsedMs = CONVERT(decimal(19,2), (d.total_elapsed_time / 1000.0) / NULLIF(d.execution_count, 0)),
        TotalLogicalReads = CONVERT(decimal(19,2), d.total_logical_reads),
        AvgLogicalReads = CONVERT(decimal(19,2), d.total_logical_reads * 1.0 / NULLIF(d.execution_count, 0)),
        TotalPhysicalReads = CONVERT(decimal(19,2), d.total_physical_reads),
        AvgPhysicalReads = CONVERT(decimal(19,2), d.total_physical_reads * 1.0 / NULLIF(d.execution_count, 0)),
        TotalWrites = CONVERT(decimal(19,2), d.total_logical_writes),
        AvgWrites = CONVERT(decimal(19,2), d.total_logical_writes * 1.0 / NULLIF(d.execution_count, 0)),
        RawSqlText = CONVERT(nvarchar(max), st.text)
    FROM Deduplicated d
    CROSS APPLY sys.dm_exec_sql_text(d.sql_handle) st
    OUTER APPLY
    (
        SELECT TOP (1) value
        FROM sys.dm_exec_plan_attributes(d.plan_handle)
        WHERE attribute = 'dbid'
    ) pa
    WHERE d.rn = 1
)
SELECT
    RankingCategory,
    DatabaseName,
    query_hash,
    query_plan_hash,
    execution_count,
    creation_time,
    last_execution_time,
    TotalCpuMs,
    AvgCpuMs,
    TotalElapsedMs,
    AvgElapsedMs,
    TotalLogicalReads,
    AvgLogicalReads,
    TotalPhysicalReads,
    AvgPhysicalReads,
    TotalWrites,
    AvgWrites,
    SqlText = LEFT(REPLACE(REPLACE(RawSqlText, CHAR(13), ' '), CHAR(10), ' '), $MaxSqlTextLength)
INTO #CandidateDetails
FROM Enriched
WHERE RawSqlText NOT LIKE '%MetricSnapshot%'
  AND RawSqlText NOT LIKE '%MetricTextSnapshot%'
  AND RawSqlText NOT LIKE '%CollectionRunHistory%'
  AND RawSqlText NOT LIKE '%SQLSentinel%'
  AND RawSqlText NOT LIKE '%sys.dm_exec_query_stats%';

SELECT
    TopCpuQueryCount = SUM(CASE WHEN RankingCategory = 'CPU' THEN 1 ELSE 0 END),
    TopDurationQueryCount = SUM(CASE WHEN RankingCategory = 'Duration' THEN 1 ELSE 0 END),
    TopLogicalReadQueryCount = SUM(CASE WHEN RankingCategory = 'LogicalReads' THEN 1 ELSE 0 END),
    TopExecutionQueryCount = SUM(CASE WHEN RankingCategory = 'Executions' THEN 1 ELSE 0 END),
    DistinctQueriesCaptured = COUNT(DISTINCT
        CONCAT(
            CONVERT(varchar(34), query_hash, 1), ':',
            CONVERT(varchar(34), query_plan_hash, 1)
        ))
FROM #CandidateDetails;

SELECT
    RankingCategory,
    DatabaseName,
    QueryHash = CONVERT(varchar(34), query_hash, 1),
    QueryPlanHash = CONVERT(varchar(34), query_plan_hash, 1),
    execution_count,
    creation_time,
    last_execution_time,
    TotalCpuMs,
    AvgCpuMs,
    TotalElapsedMs,
    AvgElapsedMs,
    TotalLogicalReads,
    AvgLogicalReads,
    TotalPhysicalReads,
    AvgPhysicalReads,
    TotalWrites,
    AvgWrites,
    SqlText
FROM #CandidateDetails
ORDER BY
    CASE RankingCategory
        WHEN 'CPU' THEN 1
        WHEN 'Duration' THEN 2
        WHEN 'LogicalReads' THEN 3
        WHEN 'Executions' THEN 4
        ELSE 5
    END,
    TotalCpuMs DESC,
    TotalElapsedMs DESC,
    TotalLogicalReads DESC;

DROP TABLE #CandidateDetails;
DROP TABLE #Candidates;
"@

            try {
                $results = Invoke-DbaQuery `
                    -SqlInstance $TargetInstance `
                    -SqlCredential $SqlCredential `
                    -Database master `
                    -Query $queryStatsQuery `
                    -As DataSet `
                    -QueryTimeout $QueryTimeout `
                    -EnableException
            }
            catch {
                throw "Invoke-DbaQuery failed on $TargetInstance while collecting query stats: $($_.Exception.Message)"
            }

            $captureTime = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

            if ($null -ne $results -and
                $results -is [System.Data.DataSet] -and
                $results.Tables.Count -gt 0 -and
                $results.Tables[0].Rows.Count -gt 0) {

                $summary = $results.Tables[0].Rows[0]

                $summaryMetrics = @(
                    @{ Name = "TopCpuQueryCount"; Value = [decimal]$summary.TopCpuQueryCount; Unit = "count" },
                    @{ Name = "TopDurationQueryCount"; Value = [decimal]$summary.TopDurationQueryCount; Unit = "count" },
                    @{ Name = "TopLogicalReadQueryCount"; Value = [decimal]$summary.TopLogicalReadQueryCount; Unit = "count" },
                    @{ Name = "TopExecutionQueryCount"; Value = [decimal]$summary.TopExecutionQueryCount; Unit = "count" },
                    @{ Name = "DistinctQueriesCaptured"; Value = [decimal]$summary.DistinctQueriesCaptured; Unit = "count" }
                )

                foreach ($metric in $summaryMetrics) {
                    Invoke-DbaQuery `
                        -SqlInstance $CentralSqlInstance `
                        -SqlCredential $SqlCredential `
                        -Database $CentralDatabase `
                        -Query @"
INSERT INTO dbo.MetricSnapshot
(
    InstanceId, CaptureTime, DatabaseName, ObjectName, CounterName,
    InstanceName, MetricCategory, MetricValue, MetricType, Unit, SourceCollector
)
VALUES
(
    $InstanceId, '$captureTime', NULL, 'QueryStatsSummary', '$($metric.Name)',
    NULL, 'QueryStats', $($metric.Value), 'Gauge', '$($metric.Unit)', '$CollectorName'
);
"@ `
                        -QueryTimeout $QueryTimeout | Out-Null

                    $RowsCollected++
                }
            }

            if ($null -ne $results -and
                $results -is [System.Data.DataSet] -and
                $results.Tables.Count -gt 1) {

                foreach ($detail in $results.Tables[1].Rows) {
                    $safeDatabaseName = if ([string]::IsNullOrWhiteSpace([string]$detail.DatabaseName)) { "(unknown)" } else { [string]$detail.DatabaseName }
                    $safeRankingCategory = if ([string]::IsNullOrWhiteSpace([string]$detail.RankingCategory)) { "(unknown)" } else { [string]$detail.RankingCategory }
                    $safeSqlText = if ([string]::IsNullOrWhiteSpace([string]$detail.SqlText)) { "(unavailable)" } else { [string]$detail.SqlText }

                    $detailText = @"
RankingCategory: $safeRankingCategory
DatabaseName: $safeDatabaseName
QueryHash: $($detail.QueryHash)
QueryPlanHash: $($detail.QueryPlanHash)
CreationTime: $($detail.creation_time)
LastExecutionTime: $($detail.last_execution_time)
ExecutionCount: $($detail.execution_count)
TotalCpuMs: $($detail.TotalCpuMs)
AvgCpuMs: $($detail.AvgCpuMs)
TotalElapsedMs: $($detail.TotalElapsedMs)
AvgElapsedMs: $($detail.AvgElapsedMs)
TotalLogicalReads: $($detail.TotalLogicalReads)
AvgLogicalReads: $($detail.AvgLogicalReads)
TotalPhysicalReads: $($detail.TotalPhysicalReads)
AvgPhysicalReads: $($detail.AvgPhysicalReads)
TotalWrites: $($detail.TotalWrites)
AvgWrites: $($detail.AvgWrites)
SQL text: $safeSqlText
"@

                    $safeDetails = $detailText.Replace("'", "''")
                    $safeDatabaseForSql = $safeDatabaseName.Replace("'", "''")

                    Invoke-DbaQuery `
                        -SqlInstance $CentralSqlInstance `
                        -SqlCredential $SqlCredential `
                        -Database $CentralDatabase `
                        -Query @"
INSERT INTO dbo.MetricTextSnapshot
(
    InstanceId, CaptureTime, DatabaseName, MetricCategory, DetailType,
    Severity, NumericValue1, NumericValue2, Details, SourceCollector
)
VALUES
(
    $InstanceId, '$captureTime', N'$safeDatabaseForSql', 'QueryStats',
    'QueryStatsDetail', 'Info', $([decimal]$detail.AvgCpuMs),
    $([decimal]$detail.AvgElapsedMs), N'$safeDetails', '$CollectorName'
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
