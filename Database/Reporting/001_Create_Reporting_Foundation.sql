/*
===============================================================================
 SQLSentinel - Reporting Foundation
 Power BI import-mode reporting objects
===============================================================================
 Run in the SQLMonitoring repository database.
===============================================================================
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'rpt')
    EXEC(N'CREATE SCHEMA rpt AUTHORIZATION dbo;');
GO

CREATE OR ALTER VIEW rpt.vw_InstanceInventory
AS
SELECT
    mi.InstanceId, mi.InstanceName, mi.EnvironmentName, mi.IsEnabled,
    mi.CollectionProfile, mi.ComplianceProfile, mi.SqlVersion, mi.Edition,
    mi.CreatedAt, mi.ModifiedAt, mi.Notes
FROM dbo.MonitoredInstances AS mi;
GO

CREATE OR ALTER VIEW rpt.vw_MetricLatest
AS
WITH Ranked AS
(
    SELECT
        ms.InstanceId, ms.CaptureTime, ms.DatabaseName, ms.ObjectName,
        ms.CounterName, ms.InstanceName AS CounterInstanceName,
        ms.MetricCategory, ms.MetricValue, ms.MetricType, ms.Unit,
        ms.SourceCollector,
        rn = ROW_NUMBER() OVER
        (
            PARTITION BY ms.InstanceId, ISNULL(ms.DatabaseName,N''),
                ISNULL(ms.ObjectName,N''), ISNULL(ms.CounterName,N''),
                ISNULL(ms.InstanceName,N''), ISNULL(ms.MetricCategory,N''),
                ISNULL(ms.SourceCollector,N'')
            ORDER BY ms.CaptureTime DESC
        )
    FROM dbo.MetricSnapshot AS ms
)
SELECT
    r.InstanceId, mi.InstanceName, mi.EnvironmentName,
    mi.CollectionProfile, mi.ComplianceProfile, r.CaptureTime,
    r.DatabaseName, r.ObjectName, r.CounterName, r.CounterInstanceName,
    r.MetricCategory, r.MetricValue, r.MetricType, r.Unit, r.SourceCollector
FROM Ranked AS r
INNER JOIN dbo.MonitoredInstances AS mi ON mi.InstanceId = r.InstanceId
WHERE r.rn = 1;
GO

CREATE OR ALTER VIEW rpt.vw_MetricTrend
AS
SELECT
    ms.InstanceId, mi.InstanceName, mi.EnvironmentName,
    mi.CollectionProfile, mi.ComplianceProfile, ms.CaptureTime,
    ms.DatabaseName, ms.ObjectName, ms.CounterName,
    ms.InstanceName AS CounterInstanceName, ms.MetricCategory,
    ms.MetricValue, ms.MetricType, ms.Unit, ms.SourceCollector
FROM dbo.MetricSnapshot AS ms
INNER JOIN dbo.MonitoredInstances AS mi ON mi.InstanceId = ms.InstanceId;
GO

CREATE OR ALTER VIEW rpt.vw_BackupComplianceCurrent
AS
WITH LatestCapture AS
(
    SELECT ms.InstanceId, MAX(ms.CaptureTime) AS CaptureTime
    FROM dbo.MetricSnapshot AS ms
    WHERE ms.SourceCollector = N'Collect-Backups'
      AND ms.MetricCategory = N'BackupCompliance'
      AND ms.ObjectName = N'BackupComplianceSummary'
    GROUP BY ms.InstanceId
), BackupSummary AS
(
    SELECT
        ms.InstanceId,
        ms.CaptureTime,
        MAX(CASE WHEN ms.CounterName = N'DatabaseCount' THEN ms.MetricValue END) AS DatabaseCount,
        MAX(CASE WHEN ms.CounterName = N'DatabasesWithoutFullBackup' THEN ms.MetricValue END) AS DatabasesWithoutFullBackup,
        MAX(CASE WHEN ms.CounterName = N'DatabasesWithOldFullBackup' THEN ms.MetricValue END) AS DatabasesWithOldFullBackup,
        MAX(CASE WHEN ms.CounterName = N'DatabasesWithOldDiffBackup' THEN ms.MetricValue END) AS DatabasesWithOldDiffBackup,
        MAX(CASE WHEN ms.CounterName = N'RecoveryModelViolations' THEN ms.MetricValue END) AS RecoveryModelViolations,
        MAX(CASE WHEN ms.CounterName = N'DatabasesWithoutRequiredLogBackup' THEN ms.MetricValue END) AS DatabasesWithoutRequiredLogBackup,
        MAX(CASE WHEN ms.CounterName = N'DatabasesWithOldRequiredLogBackup' THEN ms.MetricValue END) AS DatabasesWithOldRequiredLogBackup,
        MAX(CASE WHEN ms.CounterName = N'NonCompliantDatabaseCount' THEN ms.MetricValue END) AS NonCompliantDatabaseCount,
        MAX(CASE WHEN ms.CounterName = N'MaxFullBackupAgeHours' THEN ms.MetricValue END) AS MaxFullBackupAgeHours,
        MAX(CASE WHEN ms.CounterName = N'MaxLogBackupAgeHours' THEN ms.MetricValue END) AS MaxLogBackupAgeHours
    FROM dbo.MetricSnapshot AS ms
    INNER JOIN LatestCapture AS lc
        ON lc.InstanceId = ms.InstanceId AND lc.CaptureTime = ms.CaptureTime
    WHERE ms.SourceCollector = N'Collect-Backups'
      AND ms.MetricCategory = N'BackupCompliance'
      AND ms.ObjectName = N'BackupComplianceSummary'
    GROUP BY ms.InstanceId, ms.CaptureTime
)
SELECT
    mi.InstanceId, mi.InstanceName, mi.EnvironmentName, mi.ComplianceProfile,
    bs.CaptureTime, bs.DatabaseCount, bs.DatabasesWithoutFullBackup,
    bs.DatabasesWithOldFullBackup, bs.DatabasesWithOldDiffBackup,
    bs.RecoveryModelViolations, bs.DatabasesWithoutRequiredLogBackup,
    bs.DatabasesWithOldRequiredLogBackup, bs.NonCompliantDatabaseCount,
    bs.MaxFullBackupAgeHours, bs.MaxLogBackupAgeHours,
    BackupHealth = CASE
        WHEN bs.InstanceId IS NULL THEN N'Unknown'
        WHEN ISNULL(bs.NonCompliantDatabaseCount,0) > 0 THEN N'Critical'
        ELSE N'Healthy'
    END
FROM dbo.MonitoredInstances AS mi
LEFT JOIN BackupSummary AS bs ON bs.InstanceId = mi.InstanceId
WHERE mi.IsEnabled = 1;
GO

CREATE OR ALTER VIEW rpt.vw_CollectorHealth
AS
WITH LastRun AS
(
    SELECT
        crh.InstanceId, crh.CollectorName, crh.StartedAt, crh.FinishedAt,
        crh.Status, crh.RowsCollected, crh.DurationMs, crh.ErrorMessage,
        rn = ROW_NUMBER() OVER
        (
            PARTITION BY crh.InstanceId, crh.CollectorName
            ORDER BY crh.StartedAt DESC, crh.CollectionRunId DESC
        )
    FROM dbo.CollectionRunHistory AS crh
)
SELECT
    mi.InstanceId, mi.InstanceName, mi.EnvironmentName,
    lr.CollectorName, lr.StartedAt AS LastStartedAt,
    lr.FinishedAt AS LastFinishedAt, lr.Status AS LastStatus,
    lr.RowsCollected, lr.DurationMs, lr.ErrorMessage,
    HoursSinceLastRun = DATEDIFF(MINUTE, lr.StartedAt, SYSDATETIME()) / 60.0,
    CollectorHealth = CASE
        WHEN lr.Status IS NULL THEN N'Unknown'
        WHEN lr.Status IN (N'Failed',N'Error') THEN N'Critical'
        WHEN lr.Status = N'Running' AND lr.StartedAt < DATEADD(MINUTE,-30,SYSDATETIME()) THEN N'Warning'
        WHEN lr.StartedAt < DATEADD(HOUR,-24,SYSDATETIME()) THEN N'Warning'
        WHEN lr.Status IN (N'Success',N'Succeeded',N'Completed') THEN N'Healthy'
        ELSE N'Warning'
    END
FROM dbo.MonitoredInstances AS mi
LEFT JOIN LastRun AS lr ON lr.InstanceId = mi.InstanceId AND lr.rn = 1
WHERE mi.IsEnabled = 1;
GO

CREATE OR ALTER VIEW rpt.vw_ServerHealthCurrent
AS
WITH CollectorSummary AS
(
    SELECT
        ch.InstanceId,
        CollectorCriticalCount = SUM(CASE WHEN ch.CollectorHealth=N'Critical' THEN 1 ELSE 0 END),
        CollectorWarningCount = SUM(CASE WHEN ch.CollectorHealth=N'Warning' THEN 1 ELSE 0 END),
        LastCollectionTime = MAX(ch.LastStartedAt)
    FROM rpt.vw_CollectorHealth AS ch
    GROUP BY ch.InstanceId
)
SELECT
    mi.InstanceId, mi.InstanceName, mi.EnvironmentName,
    mi.CollectionProfile, mi.ComplianceProfile, mi.SqlVersion, mi.Edition,
    bc.CaptureTime AS BackupCaptureTime, bc.DatabaseCount,
    bc.NonCompliantDatabaseCount, bc.BackupHealth, cs.LastCollectionTime,
    ISNULL(cs.CollectorCriticalCount,0) AS CollectorCriticalCount,
    ISNULL(cs.CollectorWarningCount,0) AS CollectorWarningCount,
    OverallHealth = CASE
        WHEN ISNULL(cs.CollectorCriticalCount,0) > 0 THEN N'Critical'
        WHEN bc.BackupHealth = N'Critical' THEN N'Critical'
        WHEN ISNULL(cs.CollectorWarningCount,0) > 0 THEN N'Warning'
        WHEN bc.BackupHealth = N'Unknown' THEN N'Warning'
        ELSE N'Healthy'
    END
FROM dbo.MonitoredInstances AS mi
LEFT JOIN rpt.vw_BackupComplianceCurrent AS bc ON bc.InstanceId = mi.InstanceId
LEFT JOIN CollectorSummary AS cs ON cs.InstanceId = mi.InstanceId
WHERE mi.IsEnabled = 1;
GO

PRINT 'SQLSentinel reporting foundation created/updated successfully.';
GO
