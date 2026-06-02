<#
===============================================================================
 SQLSentinel - SQL Agent Alerts Collector
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

$CollectorName = "Collect-SqlAgentAlerts"

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
    $MaximumDetailRows = 200
    $RecentTriggerLookbackHours = 24

    if ($null -ne $config.Collectors -and
        $config.Collectors.PSObject.Properties.Name -contains "SqlAgentAlerts") {

        $alertConfig = $config.Collectors.SqlAgentAlerts

        if ($alertConfig.PSObject.Properties.Name -contains "QueryTimeoutSeconds") {
            $QueryTimeout = [int]$alertConfig.QueryTimeoutSeconds
        }

        if ($alertConfig.PSObject.Properties.Name -contains "MaximumDetailRows") {
            $MaximumDetailRows = [int]$alertConfig.MaximumDetailRows
        }

        if ($alertConfig.PSObject.Properties.Name -contains "RecentTriggerLookbackHours") {
            $RecentTriggerLookbackHours = [int]$alertConfig.RecentTriggerLookbackHours
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

        Write-Info "Collecting SQL Agent alerts from $TargetInstance"

        try {
            $CollectionRunId = Start-CollectionRun `
                -CentralSqlInstance $CentralSqlInstance `
                -CentralDatabase $CentralDatabase `
                -SqlCredential $SqlCredential `
                -InstanceId $InstanceId `
                -CollectorName $CollectorName

            $alertQuery = @"
IF OBJECT_ID('tempdb..#AlertDetails') IS NOT NULL
    DROP TABLE #AlertDetails;

SELECT
    AlertId = a.id,
    AlertName = a.name,
    IsEnabled = a.enabled,
    MessageId = a.message_id,
    SeverityNumber = a.severity,
    DatabaseName = a.database_name,
    EventDescriptionKeyword = a.event_description_keyword,
    DelayBetweenResponsesSeconds = a.delay_between_responses,
    LastOccurrenceDate = a.last_occurrence_date,
    LastOccurrenceTime = a.last_occurrence_time,
    LastResponseDate = a.last_response_date,
    LastResponseTime = a.last_response_time,
    OccurrenceCount = ISNULL(a.occurrence_count, 0),
    CountResetDate = a.count_reset_date,
    CountResetTime = a.count_reset_time,
    LastOccurrenceDateTime =
        CASE
            WHEN ISNULL(a.last_occurrence_date, 0) = 0 THEN NULL
            ELSE TRY_CONVERT(datetime2(0),
                STUFF(STUFF(CONVERT(char(8), a.last_occurrence_date), 5, 0, '-'), 8, 0, '-') + ' ' +
                STUFF(STUFF(RIGHT('000000' + CONVERT(varchar(6), a.last_occurrence_time), 6), 3, 0, ':'), 6, 0, ':')
            )
        END,
    LastResponseDateTime =
        CASE
            WHEN ISNULL(a.last_response_date, 0) = 0 THEN NULL
            ELSE TRY_CONVERT(datetime2(0),
                STUFF(STUFF(CONVERT(char(8), a.last_response_date), 5, 0, '-'), 8, 0, '-') + ' ' +
                STUFF(STUFF(RIGHT('000000' + CONVERT(varchar(6), a.last_response_time), 6), 3, 0, ':'), 6, 0, ':')
            )
        END,
    CountResetDateTime =
        CASE
            WHEN ISNULL(a.count_reset_date, 0) = 0 THEN NULL
            ELSE TRY_CONVERT(datetime2(0),
                STUFF(STUFF(CONVERT(char(8), a.count_reset_date), 5, 0, '-'), 8, 0, '-') + ' ' +
                STUFF(STUFF(RIGHT('000000' + CONVERT(varchar(6), a.count_reset_time), 6), 3, 0, ':'), 6, 0, ':')
            )
        END,
    HasNotification = CASE WHEN n.operator_id IS NULL THEN 0 ELSE 1 END,
    OperatorName = o.name,
    NotificationMethod =
        CASE n.notification_method
            WHEN 1 THEN 'Email'
            WHEN 2 THEN 'Pager'
            WHEN 4 THEN 'NetSend'
            WHEN 7 THEN 'Email/Pager/NetSend'
            ELSE
                CASE
                    WHEN n.notification_method IS NULL THEN '(none)'
                    ELSE 'Other'
                END
        END
INTO #AlertDetails
FROM msdb.dbo.sysalerts a
LEFT JOIN msdb.dbo.sysnotifications n
    ON a.id = n.alert_id
LEFT JOIN msdb.dbo.sysoperators o
    ON n.operator_id = o.id;

SELECT
    TotalAlerts = COUNT_BIG(DISTINCT AlertId),
    EnabledAlerts = COUNT_BIG(DISTINCT CASE WHEN IsEnabled = 1 THEN AlertId END),
    DisabledAlerts = COUNT_BIG(DISTINCT CASE WHEN IsEnabled = 0 THEN AlertId END),
    SeverityAlerts = COUNT_BIG(DISTINCT CASE WHEN SeverityNumber > 0 THEN AlertId END),
    ErrorNumberAlerts = COUNT_BIG(DISTINCT CASE WHEN MessageId > 0 THEN AlertId END),
    AlertsWithNotifications = COUNT_BIG(DISTINCT CASE WHEN HasNotification = 1 THEN AlertId END),
    DistinctOperators = COUNT(DISTINCT OperatorName),
    AlertsWithOccurrences = COUNT_BIG(DISTINCT CASE WHEN OccurrenceCount > 0 THEN AlertId END),
    AlertsTriggeredRecently = COUNT_BIG(DISTINCT CASE
        WHEN LastOccurrenceDateTime >= DATEADD(HOUR, -$RecentTriggerLookbackHours, SYSDATETIME())
        THEN AlertId
    END),
    AlertsRespondedRecently = COUNT_BIG(DISTINCT CASE
        WHEN LastResponseDateTime >= DATEADD(HOUR, -$RecentTriggerLookbackHours, SYSDATETIME())
        THEN AlertId
    END),
    MaxOccurrenceCount = ISNULL(MAX(OccurrenceCount), 0)
FROM #AlertDetails;

SELECT TOP ($MaximumDetailRows)
    AlertId,
    AlertName,
    IsEnabled,
    MessageId,
    SeverityNumber,
    DatabaseName,
    EventDescriptionKeyword,
    DelayBetweenResponsesSeconds,
    LastOccurrenceDate,
    LastOccurrenceTime,
    LastOccurrenceDateTime,
    LastResponseDate,
    LastResponseTime,
    LastResponseDateTime,
    OccurrenceCount,
    CountResetDate,
    CountResetTime,
    CountResetDateTime,
    HasNotification,
    OperatorName,
    NotificationMethod,
    WasTriggeredRecently =
        CASE
            WHEN LastOccurrenceDateTime >= DATEADD(HOUR, -$RecentTriggerLookbackHours, SYSDATETIME())
            THEN 1
            ELSE 0
        END
FROM #AlertDetails
ORDER BY
    WasTriggeredRecently DESC,
    OccurrenceCount DESC,
    LastOccurrenceDateTime DESC,
    IsEnabled DESC,
    AlertName,
    OperatorName;

DROP TABLE #AlertDetails;
"@

            $results = Invoke-DbaQuery `
                -SqlInstance $TargetInstance `
                -SqlCredential $SqlCredential `
                -Database msdb `
                -Query $alertQuery `
                -As DataSet `
                -QueryTimeout $QueryTimeout

            $captureTime = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

            $summary = $results.Tables[0].Rows[0]

            $summaryMetrics = @(
                @{ Name = "TotalAlerts"; Value = [decimal]$summary.TotalAlerts; Unit = "count" },
                @{ Name = "EnabledAlerts"; Value = [decimal]$summary.EnabledAlerts; Unit = "count" },
                @{ Name = "DisabledAlerts"; Value = [decimal]$summary.DisabledAlerts; Unit = "count" },
                @{ Name = "SeverityAlerts"; Value = [decimal]$summary.SeverityAlerts; Unit = "count" },
                @{ Name = "ErrorNumberAlerts"; Value = [decimal]$summary.ErrorNumberAlerts; Unit = "count" },
                @{ Name = "AlertsWithNotifications"; Value = [decimal]$summary.AlertsWithNotifications; Unit = "count" },
                @{ Name = "DistinctOperators"; Value = [decimal]$summary.DistinctOperators; Unit = "count" },
                @{ Name = "AlertsWithOccurrences"; Value = [decimal]$summary.AlertsWithOccurrences; Unit = "count" },
                @{ Name = "AlertsTriggeredRecently"; Value = [decimal]$summary.AlertsTriggeredRecently; Unit = "count" },
                @{ Name = "AlertsRespondedRecently"; Value = [decimal]$summary.AlertsRespondedRecently; Unit = "count" },
                @{ Name = "MaxOccurrenceCount"; Value = [decimal]$summary.MaxOccurrenceCount; Unit = "count" }
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
    'SqlAgentAlertSummary',
    '$($metric.Name)',
    NULL,
    'SqlAgentAlert',
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
                foreach ($alert in $results.Tables[1].Rows) {

                    $alertName = if ([string]::IsNullOrWhiteSpace([string]$alert.AlertName)) { "(unknown)" } else { [string]$alert.AlertName }
                    $operatorName = if ([string]::IsNullOrWhiteSpace([string]$alert.OperatorName)) { "(none)" } else { [string]$alert.OperatorName }
                    $notificationMethod = if ([string]::IsNullOrWhiteSpace([string]$alert.NotificationMethod)) { "(none)" } else { [string]$alert.NotificationMethod }
                    $eventKeyword = if ([string]::IsNullOrWhiteSpace([string]$alert.EventDescriptionKeyword)) { "(none)" } else { [string]$alert.EventDescriptionKeyword }
                    $alertDbName = if ([string]::IsNullOrWhiteSpace([string]$alert.DatabaseName)) { "(none)" } else { [string]$alert.DatabaseName }

                    $severity = if ([int]$alert.WasTriggeredRecently -eq 1) {
                        "Warning"
                    }
                    elseif ([int]$alert.IsEnabled -eq 0) {
                        "Warning"
                    }
                    else {
                        "Info"
                    }

                    $detailText = @"
AlertId: $($alert.AlertId)
AlertName: $alertName
IsEnabled: $($alert.IsEnabled)
MessageId: $($alert.MessageId)
SeverityNumber: $($alert.SeverityNumber)
DatabaseName: $alertDbName
EventDescriptionKeyword: $eventKeyword
DelayBetweenResponsesSeconds: $($alert.DelayBetweenResponsesSeconds)
OccurrenceCount: $($alert.OccurrenceCount)
LastOccurrenceDate: $($alert.LastOccurrenceDate)
LastOccurrenceTime: $($alert.LastOccurrenceTime)
LastOccurrenceDateTime: $($alert.LastOccurrenceDateTime)
LastResponseDate: $($alert.LastResponseDate)
LastResponseTime: $($alert.LastResponseTime)
LastResponseDateTime: $($alert.LastResponseDateTime)
CountResetDate: $($alert.CountResetDate)
CountResetTime: $($alert.CountResetTime)
CountResetDateTime: $($alert.CountResetDateTime)
WasTriggeredRecently: $($alert.WasTriggeredRecently)
HasNotification: $($alert.HasNotification)
OperatorName: $operatorName
NotificationMethod: $notificationMethod
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
    NumericValue2,
    Details,
    SourceCollector
)
VALUES
(
    $InstanceId,
    '$captureTime',
    'SqlAgentAlert',
    'AlertDetail',
    '$severity',
    $([decimal]$alert.OccurrenceCount),
    $([decimal]$alert.WasTriggeredRecently),
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