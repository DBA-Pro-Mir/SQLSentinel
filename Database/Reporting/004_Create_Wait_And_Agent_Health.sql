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
), CaptureWindow AS
(
    SELECT InstanceId,
           MAX(CASE WHEN CaptureRank=1 THEN CaptureTime END) AS CurrentCaptureTime,
           MAX(CASE WHEN CaptureRank=2 THEN CaptureTime END) AS PreviousCaptureTime
    FROM Captures WHERE CaptureRank<=2 GROUP BY InstanceId
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
 SELECT r.InstanceId,MAX(r.CaptureTime) CaptureTime,
   SUM(ISNULL(r.WaitTimeDeltaMs,0)) TotalWaitDeltaMs,
   SUM(CASE WHEN r.WaitCategory=N'Locking' THEN ISNULL(r.WaitTimeDeltaMs,0) ELSE 0 END) LockWaitDeltaMs,
   SUM(CASE WHEN r.WaitCategory=N'IO' THEN ISNULL(r.WaitTimeDeltaMs,0) ELSE 0 END) IOWaitDeltaMs,
   SUM(CASE WHEN r.WaitCategory=N'Parallelism' THEN ISNULL(r.WaitTimeDeltaMs,0) ELSE 0 END) ParallelismWaitDeltaMs,
   SUM(CASE WHEN r.WaitCategory=N'Memory' THEN ISNULL(r.WaitTimeDeltaMs,0) ELSE 0 END) MemoryWaitDeltaMs,
   SUM(CASE WHEN r.WaitCategory=N'CPU' THEN ISNULL(r.WaitTimeDeltaMs,0) ELSE 0 END) CPUWaitDeltaMs,
   SUM(CASE WHEN r.WaitCategory=N'LogIO' THEN ISNULL(r.WaitTimeDeltaMs,0) ELSE 0 END) LogIOWaitDeltaMs,
   SUM(CASE WHEN r.WaitTimeDeltaMs IS NULL THEN 1 ELSE 0 END) WaitTypesWithoutBaseline,
   SampleIntervalSeconds=DATEDIFF(SECOND,cw.PreviousCaptureTime,cw.CurrentCaptureTime)
 FROM R r JOIN CaptureWindow cw ON cw.InstanceId=r.InstanceId
 GROUP BY r.InstanceId,cw.PreviousCaptureTime,cw.CurrentCaptureTime
), N AS
(
 SELECT *,
   TotalWaitMsPerSecond=CONVERT(decimal(19,2),TotalWaitDeltaMs/NULLIF(CONVERT(decimal(19,4),SampleIntervalSeconds),0)),
   LockWaitMsPerSecond=CONVERT(decimal(19,2),LockWaitDeltaMs/NULLIF(CONVERT(decimal(19,4),SampleIntervalSeconds),0)),
   IOWaitMsPerSecond=CONVERT(decimal(19,2),IOWaitDeltaMs/NULLIF(CONVERT(decimal(19,4),SampleIntervalSeconds),0)),
   ParallelismWaitMsPerSecond=CONVERT(decimal(19,2),ParallelismWaitDeltaMs/NULLIF(CONVERT(decimal(19,4),SampleIntervalSeconds),0)),
   MemoryWaitMsPerSecond=CONVERT(decimal(19,2),MemoryWaitDeltaMs/NULLIF(CONVERT(decimal(19,4),SampleIntervalSeconds),0)),
   CPUWaitMsPerSecond=CONVERT(decimal(19,2),CPUWaitDeltaMs/NULLIF(CONVERT(decimal(19,4),SampleIntervalSeconds),0)),
   LogIOWaitMsPerSecond=CONVERT(decimal(19,2),LogIOWaitDeltaMs/NULLIF(CONVERT(decimal(19,4),SampleIntervalSeconds),0))
 FROM A
)
SELECT mi.InstanceId,mi.InstanceName,mi.EnvironmentName,n.CaptureTime,n.SampleIntervalSeconds,
 n.TotalWaitDeltaMs,n.LockWaitDeltaMs,n.IOWaitDeltaMs,n.ParallelismWaitDeltaMs,n.MemoryWaitDeltaMs,n.CPUWaitDeltaMs,n.LogIOWaitDeltaMs,
 n.TotalWaitMsPerSecond,n.LockWaitMsPerSecond,n.IOWaitMsPerSecond,n.ParallelismWaitMsPerSecond,n.MemoryWaitMsPerSecond,n.CPUWaitMsPerSecond,n.LogIOWaitMsPerSecond,n.WaitTypesWithoutBaseline,
 DominantWaitCategory=CASE WHEN n.InstanceId IS NULL THEN N'Unknown'
   WHEN n.LockWaitDeltaMs>=n.IOWaitDeltaMs AND n.LockWaitDeltaMs>=n.ParallelismWaitDeltaMs AND n.LockWaitDeltaMs>=n.MemoryWaitDeltaMs AND n.LockWaitDeltaMs>=n.CPUWaitDeltaMs AND n.LockWaitDeltaMs>=n.LogIOWaitDeltaMs AND n.LockWaitDeltaMs>0 THEN N'Locking'
   WHEN n.IOWaitDeltaMs>=n.ParallelismWaitDeltaMs AND n.IOWaitDeltaMs>=n.MemoryWaitDeltaMs AND n.IOWaitDeltaMs>=n.CPUWaitDeltaMs AND n.IOWaitDeltaMs>=n.LogIOWaitDeltaMs AND n.IOWaitDeltaMs>0 THEN N'IO'
   WHEN n.ParallelismWaitDeltaMs>=n.MemoryWaitDeltaMs AND n.ParallelismWaitDeltaMs>=n.CPUWaitDeltaMs AND n.ParallelismWaitDeltaMs>=n.LogIOWaitDeltaMs AND n.ParallelismWaitDeltaMs>0 THEN N'Parallelism'
   WHEN n.MemoryWaitDeltaMs>=n.CPUWaitDeltaMs AND n.MemoryWaitDeltaMs>=n.LogIOWaitDeltaMs AND n.MemoryWaitDeltaMs>0 THEN N'Memory'
   WHEN n.CPUWaitDeltaMs>=n.LogIOWaitDeltaMs AND n.CPUWaitDeltaMs>0 THEN N'CPU'
   WHEN n.LogIOWaitDeltaMs>0 THEN N'LogIO' ELSE N'None' END,
 WaitHealth=CASE WHEN n.InstanceId IS NULL OR n.SampleIntervalSeconds IS NULL OR n.SampleIntervalSeconds<=0 THEN N'Unknown'
   WHEN n.WaitTypesWithoutBaseline>0 AND n.TotalWaitDeltaMs=0 THEN N'Unknown'
   WHEN n.LockWaitMsPerSecond>=100 OR n.MemoryWaitMsPerSecond>=100 OR n.CPUWaitMsPerSecond>=500 OR n.IOWaitMsPerSecond>=500 OR n.LogIOWaitMsPerSecond>=500 THEN N'Critical'
   WHEN n.LockWaitMsPerSecond>=20 OR n.MemoryWaitMsPerSecond>=20 OR n.CPUWaitMsPerSecond>=100 OR n.IOWaitMsPerSecond>=100 OR n.LogIOWaitMsPerSecond>=100 OR n.ParallelismWaitMsPerSecond>=500 THEN N'Warning'
   ELSE N'Healthy' END
FROM dbo.MonitoredInstances mi LEFT JOIN N n ON n.InstanceId=mi.InstanceId WHERE mi.IsEnabled=1;
GO

CREATE OR ALTER VIEW rpt.vw_SQLAgentHealthCurrent
AS
WITH L AS
(
 SELECT ms.*,ROW_NUMBER() OVER(PARTITION BY ms.InstanceId,ms.CounterName ORDER BY ms.CaptureTime DESC) rn
 FROM dbo.MetricSnapshot ms
 WHERE ms.SourceCollector=N'Collect-SqlAgentJobs'
   AND ms.MetricCategory=N'SqlAgentJob'
   AND ms.ObjectName=N'SqlAgentJobSummary'
), A AS
(
 SELECT InstanceId,MAX(CaptureTime) CaptureTime,
  MAX(CASE WHEN CounterName=N'RecentFailedJobs' THEN MetricValue END) RecentFailedJobs,
  MAX(CASE WHEN CounterName=N'RecentCanceledJobs' THEN MetricValue END) RecentCanceledJobs,
  MAX(CASE WHEN CounterName=N'RecentRetryJobs' THEN MetricValue END) RecentRetryJobs,
  MAX(CASE WHEN CounterName=N'RecentSucceededJobs' THEN MetricValue END) RecentSucceededJobs,
  MAX(CASE WHEN CounterName=N'RecentCompletedJobs' THEN MetricValue END) RecentCompletedJobs,
  MAX(CASE WHEN CounterName=N'TotalEnabledJobs' THEN MetricValue END) TotalEnabledJobs,
  MAX(CASE WHEN CounterName=N'TotalDisabledJobs' THEN MetricValue END) TotalDisabledJobs,
  MAX(CASE WHEN CounterName=N'RunningJobCount' THEN MetricValue END) RunningJobCount,
  MAX(CASE WHEN CounterName=N'MaxRunningSeconds' THEN MetricValue END) MaxRunningSeconds,
  MAX(CASE WHEN CounterName=N'MaxRunDurationSeconds' THEN MetricValue END) MaxRunDurationSeconds,
  MAX(CASE WHEN CounterName=N'AvgRunDurationSeconds' THEN MetricValue END) AvgRunDurationSeconds
 FROM L WHERE rn=1 GROUP BY InstanceId
)
SELECT mi.InstanceId,mi.InstanceName,mi.EnvironmentName,a.CaptureTime,a.RecentFailedJobs,a.RecentCanceledJobs,a.RecentRetryJobs,a.RecentSucceededJobs,a.RecentCompletedJobs,a.TotalEnabledJobs,a.TotalDisabledJobs,a.RunningJobCount,a.MaxRunningSeconds,a.MaxRunDurationSeconds,a.AvgRunDurationSeconds,
 SQLAgentHealth=CASE
   WHEN a.InstanceId IS NULL OR a.RecentFailedJobs IS NULL THEN N'Unknown'
   WHEN a.RecentFailedJobs>0 THEN N'Critical'
   WHEN ISNULL(a.RecentCanceledJobs,0)>0 OR ISNULL(a.RecentRetryJobs,0)>0 THEN N'Warning'
   ELSE N'Healthy' END
FROM dbo.MonitoredInstances mi LEFT JOIN A a ON a.InstanceId=mi.InstanceId WHERE mi.IsEnabled=1;
GO

PRINT 'SQLSentinel normalized wait pressure and SQL Agent health views created/updated.';
GO
