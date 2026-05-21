<#
===============================================================================
 SQLSentinel - Connection and Session Collector
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

$CollectorName = "Collect-Connections"
$MaximumBreakdownRows = 100
$MinimumBreakdownSessionCount = 2

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

    $QueryTimeout = 30
    if ($null -ne $config.Collectors -and
        $null -ne $config.Collectors.Connections -and
        $null -ne $config.Collectors.Connections.QueryTimeoutSeconds) {
        $QueryTimeout = [int]$config.Collectors.Connections.QueryTimeoutSeconds
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

        Write-Info "Collecting connection metrics from $TargetInstance"

        try {
            $CollectionRunId = Start-CollectionRun `
                -CentralSqlInstance $CentralSqlInstance `
                -CentralDatabase $CentralDatabase `
                -SqlCredential $SqlCredential `
                -InstanceId $InstanceId `
                -CollectorName $CollectorName

            $sessionQuery = @"
WITH ActiveSessions AS
(
    SELECT
        login_name,
        host_name,
        program_name,
        database_id
    FROM sys.dm_exec_sessions
    WHERE is_user_process = 1
)
SELECT TOP ($MaximumBreakdownRows)
    SYSDATETIME() AS CaptureTime,
    TotalUserSessions = COUNT_BIG(1),
    DistinctLogins = COUNT(DISTINCT NULLIF(login_name, '')),
    DistinctHosts = COUNT(DISTINCT NULLIF(host_name, '')),
    DistinctApplications = COUNT(DISTINCT NULLIF(program_name, ''))
FROM ActiveSessions;

SELECT TOP ($MaximumBreakdownRows)
    SYSDATETIME() AS CaptureTime,
    BreakdownType = 'Login',
    BreakdownValue = COALESCE(NULLIF(login_name, ''), '(blank)'),
    SessionCount = COUNT_BIG(1)
FROM sys.dm_exec_sessions
WHERE is_user_process = 1
GROUP BY login_name
HAVING COUNT_BIG(1) >= $MinimumBreakdownSessionCount
ORDER BY COUNT_BIG(1) DESC;

SELECT TOP ($MaximumBreakdownRows)
    SYSDATETIME() AS CaptureTime,
    BreakdownType = 'Host',
    BreakdownValue = COALESCE(NULLIF(host_name, ''), '(blank)'),
    SessionCount = COUNT_BIG(1)
FROM sys.dm_exec_sessions
WHERE is_user_process = 1
GROUP BY host_name
HAVING COUNT_BIG(1) >= $MinimumBreakdownSessionCount
ORDER BY COUNT_BIG(1) DESC;

SELECT TOP ($MaximumBreakdownRows)
    SYSDATETIME() AS CaptureTime,
    BreakdownType = 'Application',
    BreakdownValue = COALESCE(NULLIF(program_name, ''), '(blank)'),
    SessionCount = COUNT_BIG(1)
FROM sys.dm_exec_sessions
WHERE is_user_process = 1
GROUP BY program_name
HAVING COUNT_BIG(1) >= $MinimumBreakdownSessionCount
ORDER BY COUNT_BIG(1) DESC;

SELECT TOP ($MaximumBreakdownRows)
    SYSDATETIME() AS CaptureTime,
    BreakdownType = 'Database',
    BreakdownValue = COALESCE(DB_NAME(database_id), '(unknown)'),
    SessionCount = COUNT_BIG(1)
FROM sys.dm_exec_sessions
WHERE is_user_process = 1
GROUP BY database_id
HAVING COUNT_BIG(1) >= $MinimumBreakdownSessionCount
ORDER BY COUNT_BIG(1) DESC;
"@

            $sessionResults = Invoke-DbaQuery `
                -SqlInstance $TargetInstance `
                -SqlCredential $SqlCredential `
                -Database master `
                -Query $sessionQuery `
                -As DataSet `
                -QueryTimeout $QueryTimeout

            $captureTime = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

            if ($sessionResults.Tables.Count -gt 0 -and $sessionResults.Tables[0].Rows.Count -gt 0) {
                $summaryRow = $sessionResults.Tables[0].Rows[0]
                $summaryMetrics = @(
                    @{ CounterName = "TotalUserSessions"; Value = [decimal]$summaryRow.TotalUserSessions },
                    @{ CounterName = "DistinctLogins"; Value = [decimal]$summaryRow.DistinctLogins },
                    @{ CounterName = "DistinctHosts"; Value = [decimal]$summaryRow.DistinctHosts },
                    @{ CounterName = "DistinctApplications"; Value = [decimal]$summaryRow.DistinctApplications }
                )

                foreach ($metric in $summaryMetrics) {
                    $counterName = $metric.CounterName.Replace("'", "''")

                    $insertSummaryQuery = @"
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
    N'ConnectionSummary',
    N'$counterName',
    NULL,
    'Connection',
    $($metric.Value),
    'Gauge',
    'count',
    '$CollectorName'
);
"@

                    Invoke-DbaQuery `
                        -SqlInstance $CentralSqlInstance `
                        -SqlCredential $SqlCredential `
                        -Database $CentralDatabase `
                        -Query $insertSummaryQuery `
                        -QueryTimeout 30 | Out-Null

                    $RowsCollected++
                }
            }

            for ($t = 1; $t -lt $sessionResults.Tables.Count; $t++) {
                foreach ($row in $sessionResults.Tables[$t].Rows) {
                    $breakdownType = [string]$row.BreakdownType
                    $breakdownValue = [string]$row.BreakdownValue
                    $sessionCount = [decimal]$row.SessionCount

                    $safeBreakdownType = $breakdownType.Replace("'", "''")
                    $safeBreakdownValue = $breakdownValue.Replace("'", "''")

                    $insertBreakdownQuery = @"
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
    N'ConnectionBreakdown',
    N'$safeBreakdownType',
    N'$safeBreakdownValue',
    'Connection',
    $sessionCount,
    'Gauge',
    'count',
    '$CollectorName'
);
"@

                    Invoke-DbaQuery `
                        -SqlInstance $CentralSqlInstance `
                        -SqlCredential $SqlCredential `
                        -Database $CentralDatabase `
                        -Query $insertBreakdownQuery `
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

            Write-Info "Completed $TargetInstance. Rows collected: $RowsCollected"
        }
        catch {
            $errorMessage = $_.Exception.Message
            Write-Warn "Failed collecting from $TargetInstance. $errorMessage"

            if ($null -ne $CollectionRunId) {
                Complete-CollectionRun `
                    -CentralSqlInstance $CentralSqlInstance `
                    -CentralDatabase $CentralDatabase `
                    -SqlCredential $SqlCredential `
                    -CollectionRunId $CollectionRunId `
                    -Status "Failed" `
                    -RowsCollected $RowsCollected `
                    -ErrorMessage $errorMessage
            }

            continue
        }
    }

    Write-Info "$CollectorName completed."
}
catch {
    Write-Fail $_.Exception.Message
    throw
}
