<#
===============================================================================
 SQLSentinel - SQL Agent Alerts Collector
 Captures SQL Agent alert summary, configuration issues, and triggered alerts.
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

function Get-SafeDecimal {
    param(
        [object]$Value,
        [decimal]$DefaultValue = 0
    )

    if ($null -eq $Value) { return $DefaultValue }
    if ([System.DBNull]::Value.Equals($Value)) { return $DefaultValue }
    if ([string]::IsNullOrWhiteSpace([string]$Value)) { return $DefaultValue }

    try {
        return [decimal]$Value
    }
    catch {
        return $DefaultValue
    }
}

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
        -As SingleValue `
        -EnableException
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
"@ `
        -EnableException | Out-Null
}

try {
    if (-not (Test-Path $ConfigPath)) {
        throw "Config file not found: $ConfigPath"
    }

    Import-Module dbatools

    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

    $CentralSqlInstance = $config.CentralSqlInstance
    $CentralDatabase = $config.CentralDatabase

    $QueryTimeout = 60
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
    Write-Info "Recent trigger lookback hours: $RecentTriggerLookbackHours"

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
        -QueryTimeout 30 `
        -EnableException

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
IF OBJECT_ID('tempdb..#AlertBase') IS NOT NULL
    DROP TABLE #AlertBase;

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
        END
INTO #AlertBase
FROM msdb.dbo.sysalerts a;

SELECT
    b.AlertId,
    b.AlertName,
    b.IsEnabled,
    b.MessageId,
    b.SeverityNumber,
    b.DatabaseName,
    b.EventDescriptionKeyword,
    b.DelayBetweenResponsesSeconds,
    b.LastOccurrenceDate,
    b.LastOccurrenceTime,
    b.LastOccurrenceDateTime,
    b.LastResponseDate,
    b.LastResponseTime,
    b.LastResponseDateTime,
    b.OccurrenceCount,
    b.CountResetDate,
    b.CountResetTime,
    b.CountResetDateTime,
    HasNotification =
        CASE
            WHEN EXISTS
            (
                SELECT 1
                FROM msdb.dbo.sysnotifications n
                WHERE n.alert_id = b.AlertId
            )
            THEN 1
            ELSE 0
        END,
    OperatorNames =
        ISNULL
        (
            STUFF
            (
                (
                    SELECT DISTINCT ', ' + ISNULL(o.name, '(none)')
                    FROM msdb.dbo.sysnotifications n
                    LEFT JOIN msdb.dbo.sysoperators o
                        ON n.operator_id = o.id
                    WHERE n.alert_id = b.AlertId
                    FOR XML PATH(''), TYPE
                ).value('.', 'nvarchar(max)'),
                1,
                2,
                ''
            ),
            '(none)'
        ),
    NotificationMethods =
        ISNULL
        (
            STUFF
            (
                (
                    SELECT DISTINCT ', ' +
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
                    FROM msdb.dbo.sysnotifications n
                    WHERE n.alert_id = b.AlertId
                    FOR XML PATH(''), TYPE
                ).value('.', 'nvarchar(max)'),
                1,
                2,
                ''
            ),
            '(none)'
        ),
    WasTriggeredRecently =
        CASE
            WHEN b.LastOccurrenceDateTime >= DATEADD(HOUR, -$RecentTriggerLookbackHours, SYSDATETIME())
            THEN 1
            ELSE 0
        END,
    AlertSeverity =
        CASE
            WHEN b.SeverityNumber >= 20 OR b.MessageId IN (823, 824, 825, 9001, 17053) THEN 'Critical'
            WHEN b.SeverityNumber BETWEEN 16 AND 19 THEN 'Warning'
            WHEN b.MessageId > 0 THEN 'Warning'
            ELSE 'Info'
        END
INTO #AlertDetails
FROM #AlertBase b;

SELECT
    TotalAlerts = COUNT_BIG(1),
    EnabledAlerts = SUM(CASE WHEN IsEnabled = 1 THEN 1 ELSE 0 END),
    DisabledAlerts = SUM(CASE WHEN IsEnabled = 0 THEN 1 ELSE 0 END),
    SeverityAlerts = SUM(CASE WHEN SeverityNumber > 0 THEN 1 ELSE 0 END),
    ErrorNumberAlerts = SUM(CASE WHEN MessageId > 0 THEN 1 ELSE 0 END),
    AlertsWithNotifications = SUM(CASE WHEN HasNotification = 1 THEN 1 ELSE 0 END),
    AlertsWithoutNotifications = SUM(CASE WHEN HasNotification = 0 THEN 1 ELSE 0 END),
    AlertsWithOccurrences = SUM(CASE WHEN OccurrenceCount > 0 THEN 1 ELSE 0 END),
    AlertsTriggeredRecently = SUM(CASE WHEN WasTriggeredRecently = 1 THEN 1 ELSE 0 END),
    AlertsRespondedRecently = SUM(CASE WHEN LastResponseDateTime >= DATEADD(HOUR, -$RecentTriggerLookbackHours, SYSDATETIME()) THEN 1 ELSE 0 END),
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
    OperatorNames,
    NotificationMethods,
    WasTriggeredRecently,
    AlertSeverity,
    DetailType =
        CASE
            WHEN IsEnabled = 0 THEN 'AlertConfigIssue'
            WHEN HasNotification = 0 THEN 'AlertConfigIssue'
            ELSE 'AlertConfig'
        END,
    IssueReason =
        CASE
            WHEN IsEnabled = 0 THEN 'Alert disabled'
            WHEN HasNotification = 0 THEN 'Alert has no notification'
            ELSE 'Configured'
        END
FROM #AlertDetails
WHERE IsEnabled = 0
   OR HasNotification = 0
ORDER BY
    IsEnabled,
    HasNotification,
    AlertName;

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
    OperatorNames,
    NotificationMethods,
    WasTriggeredRecently,
    AlertSeverity,
    DetailType = 'AlertTriggered',
    IssueReason = 'Alert triggered recently'
FROM #AlertDetails
WHERE IsEnabled = 1
  AND OccurrenceCount > 0
  AND WasTriggeredRecently = 1
ORDER BY
    CASE AlertSeverity
        WHEN 'Critical' THEN 1
        WHEN 'Warning' THEN 2
        ELSE 3
    END,
    LastOccurrenceDateTime DESC,
    OccurrenceCount DESC,
    AlertName;

DROP TABLE #AlertDetails;
DROP TABLE #AlertBase;
"@

            try {
                $results = Invoke-DbaQuery `
                    -SqlInstance $TargetInstance `
                    -SqlCredential $SqlCredential `
                    -Database msdb `
                    -Query $alertQuery `
                    -As DataSet `
                    -QueryTimeout $QueryTimeout `
                    -EnableException
            }
            catch {
                throw "Invoke-DbaQuery failed on $TargetInstance while collecting SQL Agent alerts: $($_.Exception.Message)"
            }

            if (
                $null -eq $results -or
                $results -isnot [System.Data.DataSet] -or
                $results.Tables.Count -eq 0 -or
                $results.Tables[0].Rows.Count -eq 0
            ) {
                throw "SQL Agent alert query did not return a valid DataSet for $TargetInstance."
            }

            $captureTime = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

            $summary = $results.Tables[0].Rows[0]

            $summaryMetrics = @(
                @{ Name = "TotalAlerts"; Value = (Get-SafeDecimal $summary.TotalAlerts); Unit = "count" },
                @{ Name = "EnabledAlerts"; Value = (Get-SafeDecimal $summary.EnabledAlerts); Unit = "count" },
                @{ Name = "DisabledAlerts"; Value = (Get-SafeDecimal $summary.DisabledAlerts); Unit = "count" },
                @{ Name = "SeverityAlerts"; Value = (Get-SafeDecimal $summary.SeverityAlerts); Unit = "count" },
                @{ Name = "ErrorNumberAlerts"; Value = (Get-SafeDecimal $summary.ErrorNumberAlerts); Unit = "count" },
                @{ Name = "AlertsWithNotifications"; Value = (Get-SafeDecimal $summary.AlertsWithNotifications); Unit = "count" },
                @{ Name = "AlertsWithoutNotifications"; Value = (Get-SafeDecimal $summary.AlertsWithoutNotifications); Unit = "count" },
                @{ Name = "AlertsWithOccurrences"; Value = (Get-SafeDecimal $summary.AlertsWithOccurrences); Unit = "count" },
                @{ Name = "AlertsTriggeredRecently"; Value = (Get-SafeDecimal $summary.AlertsTriggeredRecently); Unit = "count" },
                @{ Name = "AlertsRespondedRecently"; Value = (Get-SafeDecimal $summary.AlertsRespondedRecently); Unit = "count" },
                @{ Name = "MaxOccurrenceCount"; Value = (Get-SafeDecimal $summary.MaxOccurrenceCount); Unit = "count" }
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
                    -QueryTimeout $QueryTimeout `
                    -EnableException | Out-Null

                $RowsCollected++
            }

            $detailTableIndexes = @(1, 2)

            foreach ($tableIndex in $detailTableIndexes) {
                if ($results.Tables.Count -le $tableIndex) {
                    continue
                }

                foreach ($alert in $results.Tables[$tableIndex].Rows) {

                    $alertName = if ([string]::IsNullOrWhiteSpace([string]$alert.AlertName)) { "(unknown)" } else { [string]$alert.AlertName }
                    $operatorNames = if ([string]::IsNullOrWhiteSpace([string]$alert.OperatorNames)) { "(none)" } else { [string]$alert.OperatorNames }
                    $notificationMethods = if ([string]::IsNullOrWhiteSpace([string]$alert.NotificationMethods)) { "(none)" } else { [string]$alert.NotificationMethods }
                    $eventKeyword = if ([string]::IsNullOrWhiteSpace([string]$alert.EventDescriptionKeyword)) { "(none)" } else { [string]$alert.EventDescriptionKeyword }
                    $alertDbName = if ([string]::IsNullOrWhiteSpace([string]$alert.DatabaseName)) { "(none)" } else { [string]$alert.DatabaseName }
                    $detailType = if ([string]::IsNullOrWhiteSpace([string]$alert.DetailType)) { "AlertDetail" } else { [string]$alert.DetailType }
                    $issueReason = if ([string]::IsNullOrWhiteSpace([string]$alert.IssueReason)) { "(none)" } else { [string]$alert.IssueReason }

                    $severity = if ($detailType -eq "AlertTriggered") {
                        if ([string]::IsNullOrWhiteSpace([string]$alert.AlertSeverity)) { "Warning" } else { [string]$alert.AlertSeverity }
                    }
                    elseif ($detailType -eq "AlertConfigIssue") {
                        "Warning"
                    }
                    else {
                        "Info"
                    }

                    $occurrenceCount = Get-SafeDecimal $alert.OccurrenceCount
                    $wasTriggeredRecently = Get-SafeDecimal $alert.WasTriggeredRecently

                    $detailText = @"
AlertId: $($alert.AlertId)
AlertName: $alertName
DetailType: $detailType
IssueReason: $issueReason
IsEnabled: $($alert.IsEnabled)
MessageId: $($alert.MessageId)
SeverityNumber: $($alert.SeverityNumber)
DatabaseName: $alertDbName
EventDescriptionKeyword: $eventKeyword
DelayBetweenResponsesSeconds: $($alert.DelayBetweenResponsesSeconds)
OccurrenceCount: $occurrenceCount
LastOccurrenceDate: $($alert.LastOccurrenceDate)
LastOccurrenceTime: $($alert.LastOccurrenceTime)
LastOccurrenceDateTime: $($alert.LastOccurrenceDateTime)
LastResponseDate: $($alert.LastResponseDate)
LastResponseTime: $($alert.LastResponseTime)
LastResponseDateTime: $($alert.LastResponseDateTime)
CountResetDate: $($alert.CountResetDate)
CountResetTime: $($alert.CountResetTime)
CountResetDateTime: $($alert.CountResetDateTime)
WasTriggeredRecently: $wasTriggeredRecently
HasNotification: $($alert.HasNotification)
OperatorNames: $operatorNames
NotificationMethods: $notificationMethods
"@

                    $safeDetails = $detailText.Replace("'", "''")
                    $safeDetailType = $detailType.Replace("'", "''")
                    $safeSeverity = $severity.Replace("'", "''")

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
    '$safeDetailType',
    '$safeSeverity',
    $occurrenceCount,
    $wasTriggeredRecently,
    N'$safeDetails',
    '$CollectorName'
);
"@ `
                        -QueryTimeout $QueryTimeout `
                        -EnableException | Out-Null

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