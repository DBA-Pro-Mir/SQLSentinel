/*
 SQLSentinel - SQL Estate Health / Power BI collection-freshness reporting.
 Database: SQLMonitoring
 Purpose: Last collection attempt and last successful completed collection
          for each enabled monitored instance.
 Notes: Read-only view. Timestamps are SQLMonitoring server-local times.
        Collector status matching follows CollectionRunHistory.Status = 'Success'.
        A recent successful collector does not prove every collector is current.
*/
USE [SQLMonitoring];
GO

CREATE OR ALTER VIEW [rpt].[vw_CollectionFreshness]
AS
SELECT
    [i].[InstanceId],
    [i].[InstanceName],
    [i].[EnvironmentName],
    [i].[CollectionProfile],
    [i].[IsEnabled],

    [lastRun].[StartedAt] AS [LastAttemptAt],
    [lastRun].[FinishedAt] AS [LastAttemptFinishedAt],
    [lastRun].[Status] AS [LastAttemptStatus],
    [lastRun].[CollectorName] AS [LastAttemptCollector],

    [lastSuccess].[FinishedAt] AS [LastSuccessfulCollectionAt],
    [lastSuccess].[CollectorName] AS [LastSuccessfulCollector]

FROM [dbo].[MonitoredInstances] AS [i]

OUTER APPLY
(
    SELECT TOP (1)
        [h].[StartedAt],
        [h].[FinishedAt],
        [h].[Status],
        [h].[CollectorName]
    FROM [dbo].[CollectionRunHistory] AS [h]
    WHERE [h].[InstanceId] = [i].[InstanceId]
    ORDER BY
        [h].[StartedAt] DESC,
        [h].[CollectionRunId] DESC
) AS [lastRun]

OUTER APPLY
(
    SELECT TOP (1)
        [h].[FinishedAt],
        [h].[CollectorName]
    FROM [dbo].[CollectionRunHistory] AS [h]
    WHERE [h].[InstanceId] = [i].[InstanceId]
      AND [h].[Status] = 'Success'
      AND [h].[FinishedAt] IS NOT NULL
    ORDER BY
        [h].[FinishedAt] DESC,
        [h].[CollectionRunId] DESC
) AS [lastSuccess]

WHERE [i].[IsEnabled] = 1;
GO

-- Verify after deployment:
SELECT *
FROM [rpt].[vw_CollectionFreshness]
ORDER BY [InstanceName];
GO
