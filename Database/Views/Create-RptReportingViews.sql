USE SQLMonitoring;
GO

/* SQLSentinel rpt reporting layer.
   Current database inventory: 15 rpt views.
   This deployment script is maintained separately from the legacy dbo reporting views.
   Dependency order is documented below.

   01 vw_InstanceInventory
   02 vw_MetricLatest
   03 vw_MetricTrend
   04 vw_RepositoryHealth
   05 vw_CollectorHealth
   06 vw_DataFreshnessCurrent
   07 vw_BackupComplianceCurrent
   08 vw_BlockingHealthCurrent
   09 vw_PerformanceHealthCurrent
   10 vw_QueryPressureCurrent
   11 vw_SQLAgentHealthCurrent
   12 vw_WaitPressureCurrent
   13 vw_ServerHealthCurrent
   14 vw_ServerHealthScorecard
   15 vw_ActiveOperationalIssues
*/

CREATE OR ALTER VIEW rpt.vw_ActiveOperationalIssues
AS
SELECT s.InstanceId,s.InstanceName,s.EnvironmentName,N'CPU' IssueCategory,s.CpuHealth Severity,N'SQL Server CPU health is '+s.CpuHealth Issue,s.PerformanceCaptureTime DetectedAt,CONVERT(decimal(19,2),s.SqlProcessCpuPercent) MetricValue,N'Percent' MetricUnit,CONCAT(N'SQL CPU: ',CONVERT(varchar(30),s.SqlProcessCpuPercent),N'%, System CPU: ',CONVERT(varchar(30),s.SystemCpuPercent),N'%') Details
FROM rpt.vw_ServerHealthScorecard s WHERE s.CpuHealth IN(N'Warning',N'Critical')
UNION ALL
SELECT s.InstanceId,s.InstanceName,s.EnvironmentName,N'Memory',s.MemoryHealth,N'SQL Server memory health is '+s.MemoryHealth,s.PerformanceCaptureTime,CONVERT(decimal(19,2),s.MemoryGrantsPending),N'Pending Grants',CONCAT(N'Memory Grants Pending: ',CONVERT(varchar(30),s.MemoryGrantsPending),N', PLE: ',CONVERT(varchar(30),s.PageLifeExpectancySeconds),N' sec')
FROM rpt.vw_ServerHealthScorecard s WHERE s.MemoryHealth IN(N'Warning',N'Critical')
UNION ALL
SELECT s.InstanceId,s.InstanceName,s.EnvironmentName,N'Blocking',s.BlockingHealth,CONCAT(N'Blocking detected - ',CONVERT(varchar(30),s.BlockedSessionCount),N' blocked session(s)'),s.BlockingCaptureTime,CONVERT(decimal(19,2),s.MaxWaitSeconds),N'Seconds',CONCAT(N'Blocked sessions: ',CONVERT(varchar(30),s.BlockedSessionCount),N', Distinct blockers: ',CONVERT(varchar(30),s.DistinctBlockingSessionCount),N', Max wait: ',CONVERT(varchar(30),s.MaxWaitSeconds),N' sec')
FROM rpt.vw_ServerHealthScorecard s WHERE s.BlockingHealth IN(N'Warning',N'Critical')
UNION ALL
SELECT s.InstanceId,s.InstanceName,s.EnvironmentName,N'Deadlock',s.DeadlockHealth,CONCAT(N'Deadlocks detected - ',CONVERT(varchar(30),s.DeadlocksSincePreviousSample)),s.PerformanceCaptureTime,CONVERT(decimal(19,2),s.DeadlocksSincePreviousSample),N'Deadlocks',CONCAT(N'Deadlocks since previous sample: ',CONVERT(varchar(30),s.DeadlocksSincePreviousSample))
FROM rpt.vw_ServerHealthScorecard s WHERE s.DeadlockHealth IN(N'Warning',N'Critical')
UNION ALL
SELECT s.InstanceId,s.InstanceName,s.EnvironmentName,N'Data Freshness',s.FreshnessHealth,N'Monitoring data freshness is '+s.FreshnessHealth,s.LastCollectionAttempt,CONVERT(decimal(19,2),s.CollectorsNeverSuccessful),N'Collectors',CONCAT(N'Collectors never successful: ',CONVERT(varchar(30),s.CollectorsNeverSuccessful),N', Latest collector success: ',CONVERT(varchar(30),s.LatestCollectorSuccess,120))
FROM rpt.vw_ServerHealthScorecard s WHERE s.FreshnessHealth IN(N'Warning',N'Critical')
UNION ALL
SELECT c.InstanceId,c.InstanceName,c.EnvironmentName,N'Collector',c.CollectorHealth,CONCAT(N'Collector ',c.CollectorName,N' is ',c.CollectorHealth),c.LastStartedAt,CONVERT(decimal(19,2),c.DurationMs),N'Milliseconds',CONCAT(N'Collector: ',c.CollectorName,N'; Last status: ',ISNULL(c.LastStatus,N'Unknown'),N'; Error: ',ISNULL(c.ErrorMessage,N''))
FROM rpt.vw_CollectorHealth c WHERE c.CollectorHealth IN(N'Warning',N'Critical')
UNION ALL
SELECT a.InstanceId,a.InstanceName,a.EnvironmentName,N'SQL Agent',N'Critical',CONCAT(CONVERT(varchar(30),a.RecentFailedJobs),N' recent failed SQL Agent job(s)'),a.CaptureTime,CONVERT(decimal(19,2),a.RecentFailedJobs),N'Jobs',CONCAT(N'Failed: ',CONVERT(varchar(30),a.RecentFailedJobs),N', Canceled: ',CONVERT(varchar(30),a.RecentCanceledJobs),N', Retry: ',CONVERT(varchar(30),a.RecentRetryJobs))
FROM rpt.vw_SQLAgentHealthCurrent a WHERE ISNULL(a.RecentFailedJobs,0)>0
UNION ALL
SELECT a.InstanceId,a.InstanceName,a.EnvironmentName,N'SQL Agent',N'Warning',CONCAT(CONVERT(varchar(30),a.RecentCanceledJobs),N' recent canceled SQL Agent job(s)'),a.CaptureTime,CONVERT(decimal(19,2),a.RecentCanceledJobs),N'Jobs',CONCAT(N'Canceled: ',CONVERT(varchar(30),a.RecentCanceledJobs))
FROM rpt.vw_SQLAgentHealthCurrent a WHERE ISNULL(a.RecentCanceledJobs,0)>0
UNION ALL
SELECT a.InstanceId,a.InstanceName,a.EnvironmentName,N'SQL Agent',N'Warning',CONCAT(CONVERT(varchar(30),a.RecentRetryJobs),N' SQL Agent job retry event(s)'),a.CaptureTime,CONVERT(decimal(19,2),a.RecentRetryJobs),N'Jobs',CONCAT(N'Retry events: ',CONVERT(varchar(30),a.RecentRetryJobs))
FROM rpt.vw_SQLAgentHealthCurrent a WHERE ISNULL(a.RecentRetryJobs,0)>0;
GO
