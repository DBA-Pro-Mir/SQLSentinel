USE SQLMonitoring;
GO

CREATE OR ALTER VIEW dbo.vw_LatestMetricSnapshot
AS
WITH RankedMetrics AS
(
    SELECT
        ms.*,
        rn = ROW_NUMBER() OVER
        (
            PARTITION BY
                ms.InstanceId,
                ms.MetricCategory,
                ms.ObjectName,
                ms.CounterName,
                ISNULL(ms.DatabaseName, ''),
                ISNULL(ms.InstanceName, '')
            ORDER BY
                ms.CaptureTime DESC,
                ms.MetricSnapshotId DESC
        )
    FROM dbo.MetricSnapshot ms
)
SELECT
    MetricSnapshotId,
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
    SourceCollector,
    CreatedAt
FROM RankedMetrics
WHERE rn = 1;
GO


CREATE OR ALTER VIEW dbo.vw_InstanceHealthSummary
AS
SELECT
    mi.InstanceId,
    mi.InstanceName,
    mi.EnvironmentName,
    mi.CollectionProfile,

    UserConnections =
        MAX(CASE
            WHEN lm.MetricCategory = 'PerformanceCounter'
             AND lm.CounterName = 'User Connections'
            THEN lm.MetricValue
        END),

    ActiveRequestCount =
        MAX(CASE
            WHEN lm.MetricCategory = 'ActiveRequest'
             AND lm.CounterName = 'ActiveRequestCount'
            THEN lm.MetricValue
        END),

    BlockedSessionCount =
        MAX(CASE
            WHEN lm.MetricCategory = 'Blocking'
             AND lm.CounterName = 'BlockedSessionCount'
            THEN lm.MetricValue
        END),

    MaxBlockingWaitSeconds =
        MAX(CASE
            WHEN lm.MetricCategory = 'Blocking'
             AND lm.CounterName = 'MaxWaitSeconds'
            THEN lm.MetricValue
        END),

    FailedJobs =
        MAX(CASE
            WHEN lm.MetricCategory = 'SqlAgentJob'
             AND lm.CounterName = 'RecentFailedJobs'
            THEN lm.MetricValue
        END),

    RunningJobs =
        MAX(CASE
            WHEN lm.MetricCategory = 'SqlAgentJob'
             AND lm.CounterName = 'RunningJobCount'
            THEN lm.MetricValue
        END),

    BackupIssues =
        MAX(CASE
            WHEN lm.MetricCategory = 'Backup'
             AND lm.CounterName IN
             (
                'DatabasesWithoutFullBackup',
                'DatabasesWithOldFullBackup',
                'FullRecoveryDatabasesWithoutLogBackup',
                'FullRecoveryDatabasesWithOldLogBackup'
             )
            THEN lm.MetricValue
        END),

    TriggeredAlerts =
        MAX(CASE
            WHEN lm.MetricCategory = 'SqlAgentAlert'
             AND lm.CounterName = 'AlertsTriggeredRecently'
            THEN lm.MetricValue
        END),

    HealthStatus =
        CASE
            WHEN MAX(CASE WHEN lm.MetricCategory = 'Blocking'
                           AND lm.CounterName = 'BlockedSessionCount'
                          THEN lm.MetricValue END) > 0
              OR MAX(CASE WHEN lm.MetricCategory = 'SqlAgentJob'
                           AND lm.CounterName = 'RecentFailedJobs'
                          THEN lm.MetricValue END) > 0
              OR MAX(CASE WHEN lm.MetricCategory = 'Backup'
                           AND lm.CounterName IN
                           (
                              'DatabasesWithoutFullBackup',
                              'DatabasesWithOldFullBackup',
                              'FullRecoveryDatabasesWithoutLogBackup',
                              'FullRecoveryDatabasesWithOldLogBackup'
                           )
                          THEN lm.MetricValue END) > 0
              OR MAX(CASE WHEN lm.MetricCategory = 'SqlAgentAlert'
                           AND lm.CounterName = 'AlertsTriggeredRecently'
                          THEN lm.MetricValue END) > 0
            THEN 'Warning'
            ELSE 'Healthy'
        END,

    LastMetricCaptureTime = MAX(lm.CaptureTime)

FROM dbo.MonitoredInstances mi
LEFT JOIN dbo.vw_LatestMetricSnapshot lm
    ON mi.InstanceId = lm.InstanceId
WHERE mi.IsEnabled = 1
GROUP BY
    mi.InstanceId,
    mi.InstanceName,
    mi.EnvironmentName,
    mi.CollectionProfile;
GO


CREATE OR ALTER VIEW dbo.vw_BackupCompliance
AS
SELECT
    mts.MetricTextSnapshotId,
    mi.InstanceName,
    mi.EnvironmentName,
    mts.InstanceId,
    mts.CaptureTime,
    mts.DatabaseName,
    mts.DetailType AS BackupIssueType,
    mts.Severity,
    mts.Details,
    Status =
        CASE
            WHEN mts.DetailType IN
            (
                'MissingFullBackup',
                'MissingLogBackup'
            )
            THEN 'Critical'
            WHEN mts.DetailType IN
            (
                'OldFullBackup',
                'OldLogBackup'
            )
            THEN 'Warning'
            ELSE 'Healthy'
        END
FROM dbo.MetricTextSnapshot mts
JOIN dbo.MonitoredInstances mi
    ON mts.InstanceId = mi.InstanceId
WHERE mts.SourceCollector = 'Collect-Backups';
GO


CREATE OR ALTER VIEW dbo.vw_TopProblemQueries
AS
SELECT TOP (500)
    mts.MetricTextSnapshotId,
    mi.InstanceName,
    mi.EnvironmentName,
    mts.InstanceId,
    mts.CaptureTime,
    mts.DatabaseName,
    mts.DetailType,
    mts.Severity,
    AvgCpuMs = mts.NumericValue1,
    AvgElapsedMs = mts.NumericValue2,
    mts.Details,
    mts.SourceCollector
FROM dbo.MetricTextSnapshot mts
JOIN dbo.MonitoredInstances mi
    ON mts.InstanceId = mi.InstanceId
WHERE mts.SourceCollector = 'Collect-QueryStats'
ORDER BY
    mts.CaptureTime DESC,
    mts.NumericValue1 DESC,
    mts.NumericValue2 DESC;
GO

/*=============================================================================
  Operations Summary
=============================================================================*/

CREATE OR ALTER VIEW dbo.vw_OperationsSummary
AS
SELECT
    ihs.InstanceId,
    ihs.InstanceName,
    ihs.EnvironmentName,

    FailedJobs =
        ISNULL(ihs.FailedJobs, 0),

    RunningJobs =
        ISNULL(ihs.RunningJobs, 0),

    BackupIssues =
        ISNULL(ihs.BackupIssues, 0),

    TriggeredAlerts =
        ISNULL(ihs.TriggeredAlerts, 0),

    BlockedSessions =
        ISNULL(ihs.BlockedSessionCount, 0),

    HealthStatus =
        ihs.HealthStatus,

    LastMetricCaptureTime =
        ihs.LastMetricCaptureTime
FROM dbo.vw_InstanceHealthSummary ihs;
GO


/*=============================================================================
  Wait Stats Summary
=============================================================================*/

CREATE OR ALTER VIEW dbo.vw_WaitStatsSummary
AS
SELECT
    mts.MetricTextSnapshotId,
    mi.InstanceName,
    mi.EnvironmentName,
    mts.InstanceId,
    mts.CaptureTime,
    mts.DetailType,
    mts.Severity,
    mts.NumericValue1,
    mts.NumericValue2,
    mts.Details,
    mts.SourceCollector
FROM dbo.MetricTextSnapshot mts
INNER JOIN dbo.MonitoredInstances mi
    ON mts.InstanceId = mi.InstanceId
WHERE mts.SourceCollector = 'Collect-WaitStats';
GO


/*=============================================================================
  Database IO Summary
=============================================================================*/

CREATE OR ALTER VIEW dbo.vw_DatabaseIOSummary
AS
SELECT
    mi.InstanceName,
    mi.EnvironmentName,
    lm.InstanceId,
    lm.CaptureTime,
    lm.DatabaseName,
    lm.ObjectName,
    lm.CounterName,
    lm.MetricValue,
    lm.Unit,
    lm.SourceCollector
FROM dbo.vw_LatestMetricSnapshot lm
INNER JOIN dbo.MonitoredInstances mi
    ON lm.InstanceId = mi.InstanceId
WHERE lm.MetricCategory = 'DatabaseIO';
GO