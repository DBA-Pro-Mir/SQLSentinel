/* SQLSentinel operational health reporting views. Run in SQLMonitoring. */
SET NOCOUNT ON;
GO
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name=N'rpt') EXEC(N'CREATE SCHEMA rpt AUTHORIZATION dbo;');
GO

CREATE OR ALTER VIEW rpt.vw_PerformanceHealthCurrent AS
WITH L AS (
 SELECT ms.*, ROW_NUMBER() OVER(PARTITION BY ms.InstanceId,ms.CounterName ORDER BY ms.CaptureTime DESC) rn
 FROM dbo.MetricSnapshot ms
 WHERE ms.SourceCollector=N'Collect-PerformanceCounters'
   AND ms.CounterName IN (N'Memory Grants Pending',N'Target Server Memory (KB)',N'Total Server Memory (KB)',N'Page life expectancy',N'Number of Deadlocks/sec')
), P AS (
 SELECT InstanceId, MAX(CaptureTime) CaptureTime,
  MAX(CASE WHEN CounterName=N'Memory Grants Pending' THEN MetricValue END) MemoryGrantsPending,
  MAX(CASE WHEN CounterName=N'Target Server Memory (KB)' THEN MetricValue END) TargetServerMemoryKB,
  MAX(CASE WHEN CounterName=N'Total Server Memory (KB)' THEN MetricValue END) TotalServerMemoryKB,
  MAX(CASE WHEN CounterName=N'Page life expectancy' THEN MetricValue END) PageLifeExpectancySeconds,
  MAX(CASE WHEN CounterName=N'Number of Deadlocks/sec' THEN MetricValue END) DeadlockCounter
 FROM L WHERE rn=1 GROUP BY InstanceId
)
SELECT mi.InstanceId,mi.InstanceName,mi.EnvironmentName,p.CaptureTime,p.MemoryGrantsPending,p.TargetServerMemoryKB,p.TotalServerMemoryKB,p.PageLifeExpectancySeconds,p.DeadlockCounter,
 MemoryHealth=CASE WHEN p.InstanceId IS NULL THEN N'Unknown' WHEN ISNULL(p.MemoryGrantsPending,0)>0 THEN N'Warning' WHEN p.TargetServerMemoryKB>0 AND p.TotalServerMemoryKB < p.TargetServerMemoryKB*0.90 THEN N'Warning' ELSE N'Healthy' END,
 DeadlockHealth=CASE WHEN p.InstanceId IS NULL THEN N'Unknown' WHEN ISNULL(p.DeadlockCounter,0)>0 THEN N'Warning' ELSE N'Healthy' END
FROM dbo.MonitoredInstances mi LEFT JOIN P p ON p.InstanceId=mi.InstanceId WHERE mi.IsEnabled=1;
GO

CREATE OR ALTER VIEW rpt.vw_BlockingHealthCurrent AS
WITH L AS (
 SELECT ms.*,ROW_NUMBER() OVER(PARTITION BY ms.InstanceId,ms.CounterName ORDER BY ms.CaptureTime DESC) rn
 FROM dbo.MetricSnapshot ms WHERE ms.SourceCollector=N'Collect-Blocking' AND ms.ObjectName=N'BlockingSummary'
), B AS (
 SELECT InstanceId,MAX(CaptureTime) CaptureTime,
 MAX(CASE WHEN CounterName=N'BlockedSessionCount' THEN MetricValue END) BlockedSessionCount,
 MAX(CASE WHEN CounterName=N'DistinctBlockingSessionCount' THEN MetricValue END) DistinctBlockingSessionCount,
 MAX(CASE WHEN CounterName=N'MaxWaitSeconds' THEN MetricValue END) MaxWaitSeconds,
 MAX(CASE WHEN CounterName=N'TotalWaitSeconds' THEN MetricValue END) TotalWaitSeconds
 FROM L WHERE rn=1 GROUP BY InstanceId
)
SELECT mi.InstanceId,mi.InstanceName,mi.EnvironmentName,b.CaptureTime,b.BlockedSessionCount,b.DistinctBlockingSessionCount,b.MaxWaitSeconds,b.TotalWaitSeconds,
 BlockingHealth=CASE WHEN b.InstanceId IS NULL THEN N'Unknown' WHEN ISNULL(b.MaxWaitSeconds,0)>=60 OR ISNULL(b.BlockedSessionCount,0)>=5 THEN N'Critical' WHEN ISNULL(b.BlockedSessionCount,0)>0 THEN N'Warning' ELSE N'Healthy' END
FROM dbo.MonitoredInstances mi LEFT JOIN B b ON b.InstanceId=mi.InstanceId WHERE mi.IsEnabled=1;
GO

CREATE OR ALTER VIEW rpt.vw_QueryPressureCurrent AS
WITH L AS (
 SELECT ms.*,ROW_NUMBER() OVER(PARTITION BY ms.InstanceId,ms.CounterName ORDER BY ms.CaptureTime DESC) rn
 FROM dbo.MetricSnapshot ms WHERE ms.SourceCollector=N'Collect-QueryStats' AND ms.ObjectName=N'QueryStatsSummary'
), Q AS (
 SELECT InstanceId,MAX(CaptureTime) CaptureTime,
 MAX(CASE WHEN CounterName=N'TopCpuQueryCount' THEN MetricValue END) TopCpuQueryCount,
 MAX(CASE WHEN CounterName=N'TopDurationQueryCount' THEN MetricValue END) TopDurationQueryCount,
 MAX(CASE WHEN CounterName=N'TopLogicalReadQueryCount' THEN MetricValue END) TopLogicalReadQueryCount,
 MAX(CASE WHEN CounterName=N'TopExecutionQueryCount' THEN MetricValue END) TopExecutionQueryCount,
 MAX(CASE WHEN CounterName=N'DistinctQueriesCaptured' THEN MetricValue END) DistinctQueriesCaptured
 FROM L WHERE rn=1 GROUP BY InstanceId
)
SELECT mi.InstanceId,mi.InstanceName,mi.EnvironmentName,q.CaptureTime,q.TopCpuQueryCount,q.TopDurationQueryCount,q.TopLogicalReadQueryCount,q.TopExecutionQueryCount,q.DistinctQueriesCaptured,
 QueryDataHealth=CASE WHEN q.InstanceId IS NULL THEN N'Unknown' ELSE N'Available' END
FROM dbo.MonitoredInstances mi LEFT JOIN Q q ON q.InstanceId=mi.InstanceId WHERE mi.IsEnabled=1;
GO

CREATE OR ALTER VIEW rpt.vw_DataFreshnessCurrent AS
WITH C AS (
 SELECT InstanceId,CollectorName,MAX(StartedAt) LastStartedAt,MAX(CASE WHEN Status IN(N'Success',N'Succeeded',N'Completed') THEN FinishedAt END) LastSuccessfulAt
 FROM dbo.CollectionRunHistory GROUP BY InstanceId,CollectorName
), S AS (
 SELECT InstanceId,MAX(LastStartedAt) LastCollectionAttempt,MIN(LastSuccessfulAt) OldestCollectorSuccess,MAX(LastSuccessfulAt) LatestCollectorSuccess,
 SUM(CASE WHEN LastSuccessfulAt IS NULL THEN 1 ELSE 0 END) CollectorsNeverSuccessful
 FROM C GROUP BY InstanceId
)
SELECT mi.InstanceId,mi.InstanceName,mi.EnvironmentName,s.LastCollectionAttempt,s.OldestCollectorSuccess,s.LatestCollectorSuccess,ISNULL(s.CollectorsNeverSuccessful,0) CollectorsNeverSuccessful,
 FreshnessHealth=CASE WHEN s.InstanceId IS NULL THEN N'Unknown' WHEN ISNULL(s.CollectorsNeverSuccessful,0)>0 THEN N'Warning' WHEN s.OldestCollectorSuccess<DATEADD(HOUR,-24,SYSDATETIME()) THEN N'Warning' ELSE N'Healthy' END
FROM dbo.MonitoredInstances mi LEFT JOIN S s ON s.InstanceId=mi.InstanceId WHERE mi.IsEnabled=1;
GO

PRINT 'SQLSentinel operational health reporting views created/updated.';
GO
