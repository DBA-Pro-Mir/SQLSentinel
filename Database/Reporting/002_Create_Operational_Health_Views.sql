/* SQLSentinel operational health reporting views. Run in SQLMonitoring. */
SET NOCOUNT ON;
GO
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name=N'rpt') EXEC(N'CREATE SCHEMA rpt AUTHORIZATION dbo;');
GO

CREATE OR ALTER VIEW rpt.vw_PerformanceHealthCurrent AS
WITH Ranked AS
(
    SELECT
        ms.InstanceId,ms.CaptureTime,ms.CounterName,ms.MetricValue,
        rn=ROW_NUMBER() OVER(PARTITION BY ms.InstanceId,ms.CounterName ORDER BY ms.CaptureTime DESC),
        PreviousMetricValue=LAG(ms.MetricValue) OVER(PARTITION BY ms.InstanceId,ms.CounterName ORDER BY ms.CaptureTime)
    FROM dbo.MetricSnapshot ms
    WHERE ms.SourceCollector=N'Collect-PerformanceCounters'
      AND ms.CounterName IN
      (
        N'Memory Grants Pending',N'Target Server Memory (KB)',N'Total Server Memory (KB)',
        N'Page life expectancy',N'Number of Deadlocks/sec',N'SqlProcessCpuPercent',
        N'SystemCpuPercent',N'SystemIdlePercent'
      )
), P AS
(
    SELECT
        InstanceId,
        MAX(CaptureTime) CaptureTime,
        MAX(CASE WHEN CounterName=N'Memory Grants Pending' AND rn=1 THEN MetricValue END) MemoryGrantsPending,
        MAX(CASE WHEN CounterName=N'Target Server Memory (KB)' AND rn=1 THEN MetricValue END) TargetServerMemoryKB,
        MAX(CASE WHEN CounterName=N'Total Server Memory (KB)' AND rn=1 THEN MetricValue END) TotalServerMemoryKB,
        MAX(CASE WHEN CounterName=N'Page life expectancy' AND rn=1 THEN MetricValue END) PageLifeExpectancySeconds,
        MAX(CASE WHEN CounterName=N'Number of Deadlocks/sec' AND rn=1 THEN MetricValue END) DeadlockCounter,
        MAX(CASE WHEN CounterName=N'Number of Deadlocks/sec' AND rn=1 THEN PreviousMetricValue END) PreviousDeadlockCounter,
        MAX(CASE WHEN CounterName=N'SqlProcessCpuPercent' AND rn=1 THEN MetricValue END) SqlProcessCpuPercent,
        MAX(CASE WHEN CounterName=N'SystemCpuPercent' AND rn=1 THEN MetricValue END) SystemCpuPercent,
        MAX(CASE WHEN CounterName=N'SystemIdlePercent' AND rn=1 THEN MetricValue END) SystemIdlePercent
    FROM Ranked
    GROUP BY InstanceId
)
SELECT
    mi.InstanceId,mi.InstanceName,mi.EnvironmentName,p.CaptureTime,
    p.SqlProcessCpuPercent,p.SystemCpuPercent,p.SystemIdlePercent,
    p.MemoryGrantsPending,p.TargetServerMemoryKB,p.TotalServerMemoryKB,p.PageLifeExpectancySeconds,
    p.DeadlockCounter,
    DeadlocksSincePreviousSample=CASE
        WHEN p.DeadlockCounter IS NULL OR p.PreviousDeadlockCounter IS NULL THEN NULL
        WHEN p.DeadlockCounter < p.PreviousDeadlockCounter THEN NULL
        ELSE p.DeadlockCounter-p.PreviousDeadlockCounter
    END,
    CpuHealth=CASE
        WHEN p.InstanceId IS NULL OR p.SystemCpuPercent IS NULL THEN N'Unknown'
        WHEN p.SystemCpuPercent>=90 OR p.SqlProcessCpuPercent>=85 THEN N'Critical'
        WHEN p.SystemCpuPercent>=80 OR p.SqlProcessCpuPercent>=70 THEN N'Warning'
        ELSE N'Healthy'
    END,
    MemoryHealth=CASE
        WHEN p.InstanceId IS NULL THEN N'Unknown'
        WHEN ISNULL(p.MemoryGrantsPending,0)>=5 THEN N'Critical'
        WHEN ISNULL(p.MemoryGrantsPending,0)>0 THEN N'Warning'
        ELSE N'Healthy'
    END,
    DeadlockHealth=CASE
        WHEN p.InstanceId IS NULL OR p.DeadlockCounter IS NULL THEN N'Unknown'
        WHEN p.PreviousDeadlockCounter IS NULL THEN N'Unknown'
        WHEN p.DeadlockCounter<p.PreviousDeadlockCounter THEN N'Unknown'
        WHEN p.DeadlockCounter-p.PreviousDeadlockCounter>=5 THEN N'Critical'
        WHEN p.DeadlockCounter-p.PreviousDeadlockCounter>0 THEN N'Warning'
        ELSE N'Healthy'
    END
FROM dbo.MonitoredInstances mi
LEFT JOIN P p ON p.InstanceId=mi.InstanceId
WHERE mi.IsEnabled=1;
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
