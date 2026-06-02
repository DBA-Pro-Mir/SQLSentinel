<#
===============================================================================
 SQLSentinel - Blocking Collector
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

$CollectorName = "Collect-Blocking"

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
    $MaximumBlockingRows = 50

    if ($null -ne $config.Collectors -and
        $null -ne $config.Collectors.Blocking) {

        $blockingConfig = $config.Collectors.Blocking

        if ($blockingConfig.PSObject.Properties.Name -contains "QueryTimeoutSeconds") {
            $QueryTimeout = [int]$blockingConfig.QueryTimeoutSeconds
        }

        if ($blockingConfig.PSObject.Properties.Name -contains "MaximumBlockingRows") {
            $MaximumBlockingRows = [int]$blockingConfig.MaximumBlockingRows
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
WHERE IsEnabled = 1
ORDER BY InstanceName;
" `
        -QueryTimeout 30

    foreach ($instance in $instances) {

        $InstanceId = [int]$instance.InstanceId
        $TargetInstance = [string]$instance.InstanceName
        $RowsCollected = 0
        $CollectionRunId = $null

        Write-Info "Collecting blocking metrics from $TargetInstance"

        try {
            $CollectionRunId = Start-CollectionRun `
                -CentralSqlInstance $CentralSqlInstance `
                -CentralDatabase $CentralDatabase `
                -SqlCredential $SqlCredential `
                -InstanceId $InstanceId `
                -CollectorName $CollectorName

            $blockingQuery = @"
IF OBJECT_ID('tempdb..#BlockingDetails') IS NOT NULL
    DROP TABLE #BlockingDetails;

SELECT TOP ($MaximumBlockingRows)
    CaptureTime = SYSDATETIME(),
    BlockedSessionId = r.session_id,
    BlockingSessionId = r.blocking_session_id,
    DatabaseName = DB_NAME(r.database_id),
    WaitType = r.wait_type,
    WaitTimeMs = ISNULL(r.wait_time, 0),
    WaitSeconds = CAST(ISNULL(r.wait_time, 0) AS decimal(18,2)) / 1000.0,
    r.status,
    r.command,
    LoginName = s.login_name,
    HostName = s.host_name,
    ProgramName = s.program_name,
    SqlText = LEFT(CAST(st.text AS nvarchar(max)), 4000)
INTO #BlockingDetails
FROM sys.dm_exec_requests AS r
INNER JOIN sys.dm_exec_sessions AS s
    ON r.session_id = s.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS st
WHERE r.blocking_session_id <> 0
  AND s.is_user_process = 1
  AND ISNULL(s.program_name, '') NOT LIKE '%dbatools%'
  AND ISNULL(s.program_name, '') NOT LIKE '%PowerShell%'
  AND ISNULL(s.login_name, '') <> 'sqlsentinel'
ORDER BY
    r.wait_time DESC,
    r.session_id;

SELECT
    BlockedSessionCount = COUNT_BIG(1),
    DistinctBlockingSessionCount = COUNT(DISTINCT BlockingSessionId),
    MaxWaitSeconds = ISNULL(MAX(WaitSeconds), 0),
    TotalWaitSeconds = ISNULL(SUM(WaitSeconds), 0)
FROM #BlockingDetails;

SELECT
    CaptureTime,
    BlockedSessionId,
    BlockingSessionId,
    DatabaseName,
    WaitType,
    WaitTimeMs,
    WaitSeconds,
    status,
    command,
    LoginName,
    HostName,
    ProgramName,
    SqlText
FROM #BlockingDetails
ORDER BY
    WaitTimeMs DESC,
    BlockedSessionId;

DROP TABLE #BlockingDetails;
"@

            $results = Invoke-DbaQuery `
                -SqlInstance $TargetInstance `
                -SqlCredential $SqlCredential `
                -Database master `
                -Query $blockingQuery `
                -As DataSet `
                -QueryTimeout $QueryTimeout

            $captureTime = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

            $summary = $results.Tables[0].Rows[0]

            $summaryMetrics = @(
                @{ Name = "BlockedSessionCount"; Value = [decimal]$summary.BlockedSessionCount; Unit = "count" },
                @{ Name = "DistinctBlockingSessionCount"; Value = [decimal]$summary.DistinctBlockingSessionCount; Unit = "count" },
                @{ Name = "MaxWaitSeconds"; Value = [decimal]$summary.MaxWaitSeconds; Unit = "sec" },
                @{ Name = "TotalWaitSeconds"; Value = [decimal]$summary.TotalWaitSeconds; Unit = "sec" }
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
    'BlockingSummary',
    '$($metric.Name)',
    NULL,
    'Blocking',
    $($metric.Value),
    'Gauge',
    '$($metric.Unit)',
    '$CollectorName'
);
"@ `
                    -QueryTimeout $QueryTimeout | Out-Null

                $RowsCollected++
            }

            if ($results.Tables.Count -gt 1) {
                foreach ($detail in $results.Tables[1].Rows) {

                    $safeDatabaseName = if ([string]::IsNullOrWhiteSpace([string]$detail.DatabaseName)) { "(unknown)" } else { [string]$detail.DatabaseName }
                    $safeWaitType = if ([string]::IsNullOrWhiteSpace([string]$detail.WaitType)) { "(unknown)" } else { [string]$detail.WaitType }
                    $safeStatus = if ([string]::IsNullOrWhiteSpace([string]$detail.status)) { "(unknown)" } else { [string]$detail.status }
                    $safeCommand = if ([string]::IsNullOrWhiteSpace([string]$detail.command)) { "(unknown)" } else { [string]$detail.command }
                    $safeLoginName = if ([string]::IsNullOrWhiteSpace([string]$detail.LoginName)) { "(unknown)" } else { [string]$detail.LoginName }
                    $safeHostName = if ([string]::IsNullOrWhiteSpace([string]$detail.HostName)) { "(unknown)" } else { [string]$detail.HostName }
                    $safeProgramName = if ([string]::IsNullOrWhiteSpace([string]$detail.ProgramName)) { "(unknown)" } else { [string]$detail.ProgramName }
                    $safeSqlText = if ([string]::IsNullOrWhiteSpace([string]$detail.SqlText)) { "(unavailable)" } else { [string]$detail.SqlText }

                    $detailText = @"
BlockedSessionId: $($detail.BlockedSessionId)
BlockingSessionId: $($detail.BlockingSessionId)
DatabaseName: $safeDatabaseName
WaitType: $safeWaitType
WaitTimeMs: $($detail.WaitTimeMs)
WaitSeconds: $($detail.WaitSeconds)
Status: $safeStatus
Command: $safeCommand
LoginName: $safeLoginName
HostName: $safeHostName
ProgramName: $safeProgramName
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
    'Blocking',
    'BlockingDetail',
    'Warning',
    $([decimal]$detail.WaitSeconds),
    $([decimal]$detail.BlockingSessionId),
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