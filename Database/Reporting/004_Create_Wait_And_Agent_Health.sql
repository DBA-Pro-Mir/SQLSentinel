/* SQLSentinel - Wait pressure and SQL Agent health reporting. Run in SQLMonitoring. */
SET NOCOUNT ON;
GO

CREATE OR ALTER VIEW rpt.vw_WaitPressureCurrent
AS
WITH Captures AS
(
    SELECT InstanceId,CaptureTime,
           DENSE_RANK() OVER(PARTITION BY InstanceId ORDER BY CaptureTime DESC) AS CaptureRank
    FROM dbo.MetricSnapshot
    WHERE SourceCollector=N'Collect-WaitStats' AND ObjectName=N'SQLWaitStats'
    GROUP BY InstanceId,CaptureTime
), W AS
(
    SELECT ms.InstanceId,ms.CaptureTime,ms.InstanceName AS WaitType,ms.CounterName,ms.MetricValue,c.CaptureRank
    FROM dbo.MetricSnapshot ms
    JOIN Captures c ON c.InstanceId=ms.InstanceId AND c.CaptureTime=ms.CaptureTime
    WHERE ms.SourceCollector=N'Collect-WaitStats' AND ms.ObjectName=N'SQLWaitStats' AND c.CaptureRank<=2
), D AS
(
    SELECT cur.InstanceId,cur.CaptureTime,cur.WaitType,
      WaitTimeDeltaMs=CASE WHEN prev.MetricValue IS NULL OR cur.MetricValue<prev.MetricValue THEN NULL ELSE cur.MetricValue-prev.MetricValue END
    FROM W cur
    LEFT JOIN W prev ON prev.InstanceId=cur.InstanceId AND prev.WaitType=cur.WaitType AND prev.CounterName=cur.CounterName AND prev.CaptureRank=2
    WHERE cur.CaptureRank=1 AND cur.CounterName=N'WaitTimeMs'
), R AS
(
    SELECT *,WaitCategory=CASE
      WHEN WaitType LIKE N'LCK[_]%' THEN N'Locking'
      WHEN WaitType IN(N'PAGEIOLATCH_SH',N'PAGEIOLATCH_EX',N'PAGEIOLATCH_UP',N'IO_COMPLETION',N'ASYNC_IO_COMPLETION') THEN N'IO'
      WHEN WaitType IN(N'CXPACKET',N'CXCONSUMER') THEN N'Parallelism'
      WHEN WaitType IN(N'RESOURCE_SEMAPHORE',N'CMEMTHREAD') THEN N'Memory'
      WHEN WaitType IN(N'SOS_SCHEDULER_YIELD',N'THREADPOOL') THEN N'CPU'
      WHEN WaitType LIKE N'WRITELOG%' THEN N'LogIO'
      ELSE N'Other' END
    FROM D
), A AS
(
 SELECT InstanceId,MAX(CaptureTime) CaptureTime,
   SUM(ISNULL(WaitTimeDeltaMs,0)) TotalWaitDeltaMs,
   SUM(CASE WHEN WaitCategory=N'Locking' THEN ISNULL(WaitTimeDeltaMs,0) ELSE 0 END) LockWaitDeltaMs,
   SUM(CASE WHEN WaitCategory=N'IO' THEN ISNULL(WaitTimeDeltaMs,0) ELSE 0 END) IOWaitDeltaMs,
   SUM(CASE WHEN WaitCategory=N'Parallelism' THEN ISNULL(WaitTimeDeltaMs,0) ELSE 0 END) ParallelismWaitDeltaMs,
   SUM(CASE WHEN WaitCategory=N'Memory' THEN ISNULL(WaitTimeDeltaMs,0) ELSE 0 END) MemoryWaitDeltaMs,
   SUM(CASE WHEN WaitCategory=N'CPU' THEN ISNULL(WaitTimeDeltaMs,0) ELSE 0 END) CPUWaitDeltaMs,
   SUM(CASE WHEN WaitCategory=N'LogIO' THEN ISNULL(WaitTimeDeltaMs,0) ELSE 0 END) LogIOWaitDeltaMs,
   SUM(CASE WHEN WaitTimeDeltaMs IS NULL THEN 1 ELSE 0 END) WaitTypesWithoutBaseline
 FROM R GROUP BY InstanceId
)
SELECT mi.InstanceId,mi.InstanceName,mi.EnvironmentName,a.CaptureTime,a.TotalWaitDeltaMs,a.LockWaitDeltaMs,a.IOWaitDeltaMs,a.ParallelismWaitDeltaMs,a.MemoryWaitDeltaMs,a.CPUWaitDeltaMs,a.LogIOWaitDeltaMs,a.WaitTypesWithoutBaseline,
 DominantWaitCategory=CASE WHEN a.InstanceId IS NULL THEN N'Unknown'
   WHEN a.LockWaitDeltaMs>=a.IOWaitDeltaMs AND a.LockWaitDeltaMs>=a.ParallelismWaitDeltaMs AND a.LockWaitDeltaMs>=a.MemoryWaitDeltaMs AND a.LockWaitDeltaMs>=a.CPUWaitDeltaMs AND a.LockWaitDeltaMs>=a.LogIOWaitDeltaMs AND a.LockWaitDeltaMs>0 THEN N'Locking'
   WHEN a.IOWaitDeltaMs>=a.ParallelismWaitDeltaMs AND a.IOWaitDeltaMs>=a.MemoryWaitDeltaMs AND a.IOWaitDeltaMs>=a.CPUWaitDeltaMs AND a.IOWaitDeltaMs>=a.LogIOWaitDeltaMs AND a.IOWaitDeltaMs>0 THEN N'IO'
   WHEN a.ParallelismWaitDeltaMs>=a.MemoryWaitDeltaMs AND a.ParallelismWaitDeltaMs>=a.CPUWaitDeltaMs AND a.ParallelismWaitDeltaMs>=a.LogIOWaitDeltaMs AND a.ParallelismWaitDeltaMs>0 THEN N'Parallelism'
   WHEN a.MemoryWaitDeltaMs>=a.CPUWaitDeltaMs AND a.MemoryWaitDeltaMs>=a.LogIOWaitDeltaMs AND a.MemoryWaitDeltaMs>0 THEN N'Memory'
   WHEN a.CPUWaitDeltaMs>=a.LogIOWaitDeltaMs AND a.CPUWaitDeltaMs>0 THEN N'CPU'
   WHEN a.LogIOWaitDeltaMs>0 THEN N'LogIO' ELSE N'None' END,
 WaitHealth=CASE WHEN a.InstanceId IS NULL THEN N'Unknown' WHEN a.WaitTypesWithoutBaseline>0 AND a.TotalWaitDeltaMs=0 THEN N'Unknown'
   WHEN a.LockWaitDeltaMs>=60000 OR a.MemoryWaitDeltaMs>=60000 OR a.CPUWaitDeltaMs>=300000 OR a.IOWaitDeltaMs>=300000 OR a.LogIOWaitDeltaMs>=300000 THEN N'Critical'
   WHEN a.LockWaitDeltaMs>=10000 OR a.MemoryWaitDeltaMs>=10000 OR a.CPUWaitDeltaMs>=60000 OR a.IOWaitDeltaMs>=60000 OR a.LogIOWaitDeltaMs>=60000 OR a.ParallelismWaitDeltaMs>=300000 THEN N'Warning'
   ELSE N'Healthy' END
FROM dbo.MonitoredInstances mi LEFT JOIN A a ON a.InstanceId=mi.InstanceId WHERE mi.IsEnabled=1;
GO

/* SQL Agent view uses data only when a collector writes SQLAgent summary metrics.
   Until then it returns Unknown rather than fabricating Healthy status. */
CREATE OR ALTER VIEW rpt.vw_SQLAgentHealthCurrent
AS
WITH L AS
(
 SELECT ms.*,ROW_NUMBER() OVER(PARTITION BY ms.InstanceId,ms.CounterName ORDER BY ms.CaptureTime DESC) rn
 FROM dbo.MetricSnapshot ms
 WHERE ms.MetricCategory=N'SQLAgent' OR ms.SourceCollector IN(N'Collect-SQLAgent',N'Collect-SQLAgentJobs',N'Collect-AgentJobs')
), A AS
(
 SELECT InstanceId,MAX(CaptureTime) CaptureTime,
  MAX(CASE WHEN CounterName=N'FailedJobCount' THEN MetricValue END) FailedJobCount,
  MAX(CASE WHEN CounterName=N'DisabledJobCount' THEN MetricValue END) DisabledJobCount,
  MAX(CASE WHEN CounterName=N'RunningJobCount' THEN MetricValue END) RunningJobCount
 FROM L WHERE rn=1 GROUP BY InstanceId
)
SELECT mi.InstanceId,mi.InstanceName,mi.EnvironmentName,a.CaptureTime,a.FailedJobCount,a.DisabledJobCount,a.RunningJobCount,
 SQLAgentHealth=CASE WHEN a.InstanceId IS NULL THEN N'Unknown' WHEN ISNULL(a.FailedJobCount,0)>0 THEN N'Critical' ELSE N'Healthy' END
FROM dbo.MonitoredInstances mi LEFT JOIN A a ON a.InstanceId=mi.InstanceId WHERE mi.IsEnabled=1;
GO

PRINT 'SQLSentinel wait pressure and SQL Agent health views created/updated.';
GO
