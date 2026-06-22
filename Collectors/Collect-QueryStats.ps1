<#
===============================================================================
 SQLSentinel - Query Stats Collector
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

    Import-Module dbatools

    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

    $CentralSqlInstance = $config.CentralSqlInstance
    $CentralDatabase = $config.CentralDatabase

    $QueryTimeout = 120
    $TopQueriesPerCategory = 25
    $LookbackMinutes = 60
    $MaxSqlTextLength = 4000
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

        Write-Info "Collecting query stats from $TargetInstance"

        try {
            $CollectionRunId = Start-CollectionRun `
                -CentralSqlInstance $CentralSqlInstance `
                -CentralDatabase $CentralDatabase `
                -SqlCredential $SqlCredential `
                -InstanceId $InstanceId `
                -CollectorName $CollectorName

            $queryStatsQuery = @"
IF OBJECT_ID('tempdb..#QueryStats') IS NOT NULL
    DROP TABLE #QueryStats;

SELECT
    RankingCategory = CAST(NULL AS varchar(30)),
    DatabaseName = DB_NAME(CONVERT(int, pa.value)),
    qs.query_hash,
    qs.query_plan_hash,
    qs.execution_count,
    qs.creation_time,
    qs.last_execution_time,
    TotalCpuMs = CONVERT(decimal(19,2), qs.total_worker_time / 1000.0),
    AvgCpuMs = CONVERT(decimal(19,2), (qs.total_worker_time / 1000.0) / NULLIF(qs.execution_count, 0)),
    TotalElapsedMs = CONVERT(decimal(19,2), qs.total_elapsed_time / 1000.0),
    AvgElapsedMs = CONVERT(decimal(19,2), (qs.total_elapsed_time / 1000.0) / NULLIF(qs.execution_count, 0)),
    TotalLogicalReads = CONVERT(decimal(19,2), qs.total_logical_reads),
    AvgLogicalReads = CONVERT(decimal(19,2), qs.total_logical_reads / NULLIF(qs.execution_count, 0)),
    TotalPhysicalReads = CONVERT(decimal(19,2), qs.total_physical_reads),
    AvgPhysicalReads = CONVERT(decimal(19,2), qs.total_physical_reads / NULLIF(qs.execution_count, 0)),
    TotalWrites = CONVERT(decimal(19,2), qs.total_logical_writes),
    AvgWrites = CONVERT(decimal(19,2), qs.total_logical_writes / NULLIF(qs.execution_count, 0)),
    SqlText = LEFT(REPLACE(REPLACE(CONVERT(nvarchar(max), st.text), CHAR(13), ' '), CHAR(10), ' '), $MaxSqlTextLength)
INTO #QueryStats
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
OUTER APPLY sys.dm_exec_plan_attributes(qs.plan_handle) pa
WHERE pa.attribute = 'dbid'
  AND qs.last_execution_time >= DATEADD(MINUTE, -$LookbackMinutes, SYSDATETIME())
  AND qs.execution_count >= $MinimumExecutionCount
  AND CONVERT(nvarchar(max), st.text) NOT LIKE '%MetricSnapshot%'
  AND CONVERT(nvarchar(max), st.text) NOT LIKE '%MetricTextSnapshot%'
  AND CONVERT(nvarchar(max), st.text) NOT LIKE '%CollectionRunHistory%'
  AND CONVERT(nvarchar(max), st.text) NOT LIKE '%SQLSentinel%'
  AND CONVERT(nvarchar(max), st.text) NOT LIKE '%sys.dm_exec_query_stats%';

IF OBJECT_ID('tempdb..#WorstQueries') IS NOT NULL
    DROP TABLE #WorstQueries;

CREATE TABLE #WorstQueries
(
    RankingCategory varchar(30) NOT NULL,
    DatabaseName sysname NULL,
    query_hash binary(8) NULL,
    query_plan_hash binary(8) NULL,
    execution_count bigint NOT NULL,
    creation_time datetime NOT NULL,
    last_execution_time datetime NOT NULL,
    TotalCpuMs decimal(19,2) NULL,
    AvgCpuMs decimal(19,2) NULL,
    TotalElapsedMs decimal(19,2) NULL,
    AvgElapsedMs decimal(19,2) NULL,
    TotalLogicalReads decimal(19,2) NULL,
    AvgLogicalReads decimal(19,2) NULL,
    TotalPhysicalReads decimal(19,2) NULL,
    AvgPhysicalReads decimal(19,2) NULL,
    TotalWrites decimal(19,2) NULL,
    AvgWrites decimal(19,2) NULL,
    SqlText nvarchar(max) NULL
);

INSERT INTO #WorstQueries
SELECT TOP ($TopQueriesPerCategory)
    'CPU',
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
    SqlText
FROM #QueryStats
ORDER BY TotalCpuMs DESC;

INSERT INTO #WorstQueries
SELECT TOP ($TopQueriesPerCategory)
    'Duration',
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
    SqlText
FROM #QueryStats
ORDER BY TotalElapsedMs DESC;

INSERT INTO #WorstQueries
SELECT TOP ($TopQueriesPerCategory)
    'LogicalReads',
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
    SqlText
FROM #QueryStats
ORDER BY TotalLogicalReads DESC;

INSERT INTO #WorstQueries
SELECT TOP ($TopQueriesPerCategory)
    'Executions',
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
    SqlText
FROM #QueryStats
ORDER BY execution_count DESC;

SELECT
    TopCpuQueryCount =
        SUM(CASE WHEN RankingCategory = 'CPU' THEN 1 ELSE 0 END),
    TopDurationQueryCount =
        SUM(CASE WHEN RankingCategory = 'Duration' THEN 1 ELSE 0 END),
    TopLogicalReadQueryCount =
        SUM(CASE WHEN RankingCategory = 'LogicalReads' THEN 1 ELSE 0 END),
    TopExecutionQueryCount =
        SUM(CASE WHEN RankingCategory = 'Executions' THEN 1 ELSE 0 END),
    DistinctQueriesCaptured =
        COUNT(DISTINCT CONVERT(varchar(34), query_hash, 1))
FROM #WorstQueries;

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
FROM #WorstQueries
ORDER BY
    RankingCategory,
    TotalCpuMs DESC,
    TotalElapsedMs DESC,
    TotalLogicalReads DESC;

DROP TABLE #WorstQueries;
DROP TABLE #QueryStats;
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

            if (
                $null -ne $results -and
                $results -is [System.Data.DataSet] -and
                $results.Tables.Count -gt 0 -and
                $results.Tables[0].Rows.Count -gt 0
            ) {

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
    'QueryStatsSummary',
    '$($metric.Name)',
    NULL,
    'QueryStats',
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

            if (
                $null -ne $results -and
                $results -is [System.Data.DataSet] -and
                $results.Tables.Count -gt 1
            ) {
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
    N'$($safeDatabaseName.Replace("'", "''"))',
    'QueryStats',
    'QueryStatsDetail',
    'Info',
    $([decimal]$detail.AvgCpuMs),
    $([decimal]$detail.AvgElapsedMs),
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
