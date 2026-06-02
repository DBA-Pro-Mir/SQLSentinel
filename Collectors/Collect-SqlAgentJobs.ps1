<#
===============================================================================
 SQLSentinel - SQL Agent Jobs Collector
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

$CollectorName = "Collect-SqlAgentJobs"

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

    $QueryTimeout = 15
    $LookbackHours = 24
    $MaximumDetailRows = 100

    if ($null -ne $config.Collectors -and
    $config.Collectors.PSObject.Properties.Name -contains "SqlAgentJobs") {

  
        $jobConfig = $config.Collectors.SqlAgentJobs

        if ($jobConfig.PSObject.Properties.Name -contains "QueryTimeoutSeconds") {
            $QueryTimeout = [int]$jobConfig.QueryTimeoutSeconds
        }

        if ($jobConfig.PSObject.Properties.Name -contains "LookbackHours") {
            $LookbackHours = [int]$jobConfig.LookbackHours
        }

        if ($jobConfig.PSObject.Properties.Name -contains "MaximumDetailRows") {
            $MaximumDetailRows = [int]$jobConfig.MaximumDetailRows
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

        Write-Info "Collecting SQL Agent job metrics from $TargetInstance"

        try {
            $CollectionRunId = Start-CollectionRun `
                -CentralSqlInstance $CentralSqlInstance `
                -CentralDatabase $CentralDatabase `
                -SqlCredential $SqlCredential `
                -InstanceId $InstanceId `
                -CollectorName $CollectorName

            $jobQuery = @"
DECLARE @LookbackStart datetime2(0) = DATEADD(HOUR, -$LookbackHours, SYSDATETIME());

IF OBJECT_ID('tempdb..#RecentJobHistory') IS NOT NULL
    DROP TABLE #RecentJobHistory;

IF OBJECT_ID('tempdb..#RunningJobs') IS NOT NULL
    DROP TABLE #RunningJobs;

SELECT
    j.job_id,
    JobName = j.name,
    j.enabled,
    h.instance_id,
    h.step_id,
    h.step_name,
    h.run_status,
    RunStatusDescription =
        CASE h.run_status
            WHEN 0 THEN 'Failed'
            WHEN 1 THEN 'Succeeded'
            WHEN 2 THEN 'Retry'
            WHEN 3 THEN 'Canceled'
            WHEN 4 THEN 'In Progress'
            ELSE 'Unknown'
        END,
    RunDateTime =
        TRY_CONVERT(datetime2(0),
            STUFF(STUFF(CONVERT(char(8), h.run_date), 5, 0, '-'), 8, 0, '-') + ' ' +
            STUFF(STUFF(RIGHT('000000' + CONVERT(varchar(6), h.run_time), 6), 3, 0, ':'), 6, 0, ':')
        ),
    RunDurationSeconds =
        ((h.run_duration / 10000) * 3600) +
        (((h.run_duration % 10000) / 100) * 60) +
        (h.run_duration % 100),
    h.message
INTO #RecentJobHistory
FROM msdb.dbo.sysjobhistory h
INNER JOIN msdb.dbo.sysjobs j
    ON h.job_id = j.job_id
WHERE h.step_id = 0
  AND TRY_CONVERT(datetime2(0),
        STUFF(STUFF(CONVERT(char(8), h.run_date), 5, 0, '-'), 8, 0, '-') + ' ' +
        STUFF(STUFF(RIGHT('000000' + CONVERT(varchar(6), h.run_time), 6), 3, 0, ':'), 6, 0, ':')
      ) >= @LookbackStart;

SELECT
    ja.job_id,
    JobName = j.name,
    StartExecutionDate = ja.start_execution_date,
    RunningSeconds = DATEDIFF(SECOND, ja.start_execution_date, SYSDATETIME())
INTO #RunningJobs
FROM msdb.dbo.sysjobactivity ja
INNER JOIN msdb.dbo.sysjobs j
    ON ja.job_id = j.job_id
WHERE ja.start_execution_date IS NOT NULL
  AND ja.stop_execution_date IS NULL
  AND ja.session_id =
  (
      SELECT MAX(session_id)
      FROM msdb.dbo.syssessions
  );

SELECT
    TotalEnabledJobs = SUM(CASE WHEN enabled = 1 THEN 1 ELSE 0 END),
    TotalDisabledJobs = SUM(CASE WHEN enabled = 0 THEN 1 ELSE 0 END)
FROM msdb.dbo.sysjobs;

SELECT
    RecentCompletedJobs = COUNT_BIG(1),
    RecentSucceededJobs = ISNULL(SUM(CASE WHEN run_status = 1 THEN 1 ELSE 0 END), 0),
    RecentFailedJobs = ISNULL(SUM(CASE WHEN run_status = 0 THEN 1 ELSE 0 END), 0),
    RecentCanceledJobs = ISNULL(SUM(CASE WHEN run_status = 3 THEN 1 ELSE 0 END), 0),
    RecentRetryJobs = ISNULL(SUM(CASE WHEN run_status = 2 THEN 1 ELSE 0 END), 0),
    MaxRunDurationSeconds = ISNULL(MAX(RunDurationSeconds), 0),
    AvgRunDurationSeconds = ISNULL(AVG(CAST(RunDurationSeconds AS decimal(18,2))), 0)
FROM #RecentJobHistory;

SELECT
    RunningJobCount = COUNT_BIG(1),
    MaxRunningSeconds = ISNULL(MAX(RunningSeconds), 0)
FROM #RunningJobs;

SELECT TOP ($MaximumDetailRows)
    DetailType = 'JobFailure',
    Severity = 'Warning',
    JobName,
    RunDateTime,
    RunDurationSeconds,
    RunStatusDescription,
    Message
FROM #RecentJobHistory
WHERE run_status IN (0, 2, 3)
ORDER BY RunDateTime DESC;

SELECT TOP ($MaximumDetailRows)
    DetailType = 'RunningJob',
    Severity =
        CASE
            WHEN RunningSeconds >= 3600 THEN 'Warning'
            ELSE 'Info'
        END,
    JobName,
    StartExecutionDate,
    RunningSeconds
FROM #RunningJobs
ORDER BY RunningSeconds DESC;

DROP TABLE #RecentJobHistory;
DROP TABLE #RunningJobs;
"@

            $results = Invoke-DbaQuery `
                -SqlInstance $TargetInstance `
                -SqlCredential $SqlCredential `
                -Database msdb `
                -Query $jobQuery `
                -As DataSet `
                -QueryTimeout $QueryTimeout

            $captureTime = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

            $inventory = $results.Tables[0].Rows[0]
            $recent = $results.Tables[1].Rows[0]
            $running = $results.Tables[2].Rows[0]

            $metrics = @(
                @{ Name = "TotalEnabledJobs"; Value = [decimal]$inventory.TotalEnabledJobs; Unit = "count" },
                @{ Name = "TotalDisabledJobs"; Value = [decimal]$inventory.TotalDisabledJobs; Unit = "count" },
                @{ Name = "RecentCompletedJobs"; Value = [decimal]$recent.RecentCompletedJobs; Unit = "count" },
                @{ Name = "RecentSucceededJobs"; Value = [decimal]$recent.RecentSucceededJobs; Unit = "count" },
                @{ Name = "RecentFailedJobs"; Value = [decimal]$recent.RecentFailedJobs; Unit = "count" },
                @{ Name = "RecentCanceledJobs"; Value = [decimal]$recent.RecentCanceledJobs; Unit = "count" },
                @{ Name = "RecentRetryJobs"; Value = [decimal]$recent.RecentRetryJobs; Unit = "count" },
                @{ Name = "MaxRunDurationSeconds"; Value = [decimal]$recent.MaxRunDurationSeconds; Unit = "sec" },
                @{ Name = "AvgRunDurationSeconds"; Value = [decimal]$recent.AvgRunDurationSeconds; Unit = "sec" },
                @{ Name = "RunningJobCount"; Value = [decimal]$running.RunningJobCount; Unit = "count" },
                @{ Name = "MaxRunningSeconds"; Value = [decimal]$running.MaxRunningSeconds; Unit = "sec" }
            )

            foreach ($metric in $metrics) {
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
    'SqlAgentJobSummary',
    '$($metric.Name)',
    NULL,
    'SqlAgentJob',
    $($metric.Value),
    'Gauge',
    '$($metric.Unit)',
    '$CollectorName'
);
"@ `
                    -QueryTimeout $QueryTimeout | Out-Null

                $RowsCollected++
            }

            if ($results.Tables.Count -gt 3) {
                foreach ($failure in $results.Tables[3].Rows) {

                    $jobName = if ([string]::IsNullOrWhiteSpace([string]$failure.JobName)) { "(unknown)" } else { [string]$failure.JobName }
                    $message = if ([string]::IsNullOrWhiteSpace([string]$failure.Message)) { "(none)" } else { [string]$failure.Message }

                    $detailText = @"
JobName: $jobName
RunDateTime: $($failure.RunDateTime)
RunDurationSeconds: $($failure.RunDurationSeconds)
RunStatus: $($failure.RunStatusDescription)
Message: $message
"@

                    $safeDetails = $detailText.Replace("'", "''")
                    $safeJobName = $jobName.Replace("'", "''")

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
    Details,
    SourceCollector
)
VALUES
(
    $InstanceId,
    '$captureTime',
    'SqlAgentJob',
    'JobFailure',
    'Warning',
    $([decimal]$failure.RunDurationSeconds),
    N'$safeDetails',
    '$CollectorName'
);
"@ `
                        -QueryTimeout $QueryTimeout | Out-Null

                    $RowsCollected++
                }
            }

            if ($results.Tables.Count -gt 4) {
                foreach ($runningJob in $results.Tables[4].Rows) {

                    $jobName = if ([string]::IsNullOrWhiteSpace([string]$runningJob.JobName)) { "(unknown)" } else { [string]$runningJob.JobName }
                    $severity = if ([string]::IsNullOrWhiteSpace([string]$runningJob.Severity)) { "Info" } else { [string]$runningJob.Severity }

                    $detailText = @"
JobName: $jobName
StartExecutionDate: $($runningJob.StartExecutionDate)
RunningSeconds: $($runningJob.RunningSeconds)
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
    MetricCategory,
    DetailType,
    Severity,
    NumericValue1,
    Details,
    SourceCollector
)
VALUES
(
    $InstanceId,
    '$captureTime',
    'SqlAgentJob',
    'RunningJob',
    '$severity',
    $([decimal]$runningJob.RunningSeconds),
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