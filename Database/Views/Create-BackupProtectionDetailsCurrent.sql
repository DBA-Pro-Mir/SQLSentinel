USE [SQLMonitoring];
GO

IF SCHEMA_ID(N'rpt') IS NULL
    EXEC(N'CREATE SCHEMA [rpt] AUTHORIZATION [dbo];');
GO

/*
 SQLSentinel - Database-level backup protection details (latest collector run)
 Source: dbo.MetricTextSnapshot, joined to the latest backup summary capture.
 Important: Collect-Backups currently limits detail collection to MaximumDetailRows
 (default 200) per instance/run; this view does not invent omitted records.
*/
CREATE OR ALTER VIEW [rpt].[vw_BackupProtectionDetailsCurrent]
AS
WITH [LatestCapture] AS
(
    SELECT
        [ms].[InstanceId],
        MAX([ms].[CaptureTime]) AS [CaptureTime]
    FROM [dbo].[MetricSnapshot] AS [ms]
    WHERE [ms].[SourceCollector] = N'Collect-Backups'
      AND [ms].[MetricCategory] = N'BackupCompliance'
      AND [ms].[ObjectName] = N'BackupComplianceSummary'
    GROUP BY [ms].[InstanceId]
)
SELECT
    [mi].[InstanceId],
    [mi].[InstanceName],
    [mi].[EnvironmentName],
    [mi].[ComplianceProfile],
    [mts].[DatabaseName],
    [IssueType] = [mts].[DetailType],
    [mts].[Severity],
    [FullBackupAgeHours] = [mts].[NumericValue1],
    [mts].[CaptureTime],
    [mts].[Details]
FROM [dbo].[MetricTextSnapshot] AS [mts]
INNER JOIN [dbo].[MonitoredInstances] AS [mi]
    ON [mi].[InstanceId] = [mts].[InstanceId]
INNER JOIN [LatestCapture] AS [lc]
    ON [lc].[InstanceId] = [mts].[InstanceId]
   AND [lc].[CaptureTime] = [mts].[CaptureTime]
WHERE [mts].[SourceCollector] = N'Collect-Backups'
  AND [mts].[MetricCategory] = N'BackupCompliance'
  AND [mi].[IsEnabled] = 1;
GO
