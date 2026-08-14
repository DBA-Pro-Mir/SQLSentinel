/*
===============================================================================
 SQLSentinel - Consolidated Server Health Scorecard
 Power BI Page 1 source
===============================================================================
 Prerequisites:
   001_Create_Reporting_Foundation.sql
   002_Create_Operational_Health_Views.sql
===============================================================================
*/
SET NOCOUNT ON;
GO

CREATE OR ALTER VIEW rpt.vw_ServerHealthScorecard
AS
WITH CollectorSummary AS
(
    SELECT
        InstanceId,
        CollectorCriticalCount = SUM(CASE WHEN CollectorHealth = N'Critical' THEN 1 ELSE 0 END),
        CollectorWarningCount  = SUM(CASE WHEN CollectorHealth = N'Warning'  THEN 1 ELSE 0 END),
        CollectorUnknownCount  = SUM(CASE WHEN CollectorHealth = N'Unknown'  THEN 1 ELSE 0 END),
        LastCollectionTime = MAX(LastStartedAt)
    FROM rpt.vw_CollectorHealth
    GROUP BY InstanceId
), Base AS
(
    SELECT
        mi.InstanceId,
        mi.InstanceName,
        mi.EnvironmentName,
        mi.CollectionProfile,
        mi.ComplianceProfile,
        mi.SqlVersion,
        mi.Edition,

        ph.CaptureTime AS PerformanceCaptureTime,
        ph.SqlProcessCpuPercent,
        ph.SystemCpuPercent,
        ph.MemoryGrantsPending,
        ph.PageLifeExpectancySeconds,
        ph.DeadlocksSincePreviousSample,
        ph.CpuHealth,
        ph.MemoryHealth,
        ph.DeadlockHealth,

        bh.CaptureTime AS BlockingCaptureTime,
        bh.BlockedSessionCount,
        bh.DistinctBlockingSessionCount,
        bh.MaxWaitSeconds,
        bh.BlockingHealth,

        bc.CaptureTime AS BackupCaptureTime,
        bc.DatabaseCount,
        bc.BackupProtectionIssueCount,
        bc.ConfigurationViolationCount,
        bc.BackupHealth,
        bc.ConfigurationHealth,

        q.CaptureTime AS QueryStatsCaptureTime,
        q.DistinctQueriesCaptured,
        q.QueryDataHealth,

        df.LastCollectionAttempt,
        df.LatestCollectorSuccess,
        df.CollectorsNeverSuccessful,
        df.FreshnessHealth,

        ISNULL(cs.CollectorCriticalCount,0) AS CollectorCriticalCount,
        ISNULL(cs.CollectorWarningCount,0) AS CollectorWarningCount,
        ISNULL(cs.CollectorUnknownCount,0) AS CollectorUnknownCount,
        cs.LastCollectionTime
    FROM dbo.MonitoredInstances AS mi
    LEFT JOIN rpt.vw_PerformanceHealthCurrent AS ph ON ph.InstanceId = mi.InstanceId
    LEFT JOIN rpt.vw_BlockingHealthCurrent AS bh ON bh.InstanceId = mi.InstanceId
    LEFT JOIN rpt.vw_BackupComplianceCurrent AS bc ON bc.InstanceId = mi.InstanceId
    LEFT JOIN rpt.vw_QueryPressureCurrent AS q ON q.InstanceId = mi.InstanceId
    LEFT JOIN rpt.vw_DataFreshnessCurrent AS df ON df.InstanceId = mi.InstanceId
    LEFT JOIN CollectorSummary AS cs ON cs.InstanceId = mi.InstanceId
    WHERE mi.IsEnabled = 1
)
SELECT
    b.*,
    HealthScore = CONVERT(int,
        CASE
            WHEN 100
               - CASE b.CpuHealth WHEN N'Critical' THEN 20 WHEN N'Warning' THEN 10 WHEN N'Unknown' THEN 5 ELSE 0 END
               - CASE b.MemoryHealth WHEN N'Critical' THEN 20 WHEN N'Warning' THEN 10 WHEN N'Unknown' THEN 5 ELSE 0 END
               - CASE b.BlockingHealth WHEN N'Critical' THEN 20 WHEN N'Warning' THEN 10 WHEN N'Unknown' THEN 5 ELSE 0 END
               - CASE b.DeadlockHealth WHEN N'Critical' THEN 15 WHEN N'Warning' THEN 8 WHEN N'Unknown' THEN 0 ELSE 0 END
               - CASE b.BackupHealth WHEN N'Critical' THEN 25 WHEN N'Warning' THEN 10 WHEN N'Unknown' THEN 5 ELSE 0 END
               - CASE b.ConfigurationHealth WHEN N'Critical' THEN 10 WHEN N'Warning' THEN 5 WHEN N'Unknown' THEN 3 ELSE 0 END
               - CASE b.FreshnessHealth WHEN N'Critical' THEN 25 WHEN N'Warning' THEN 15 WHEN N'Unknown' THEN 10 ELSE 0 END
               - CASE WHEN b.CollectorCriticalCount > 0 THEN 25 WHEN b.CollectorWarningCount > 0 THEN 10 ELSE 0 END
               < 0 THEN 0
            ELSE 100
               - CASE b.CpuHealth WHEN N'Critical' THEN 20 WHEN N'Warning' THEN 10 WHEN N'Unknown' THEN 5 ELSE 0 END
               - CASE b.MemoryHealth WHEN N'Critical' THEN 20 WHEN N'Warning' THEN 10 WHEN N'Unknown' THEN 5 ELSE 0 END
               - CASE b.BlockingHealth WHEN N'Critical' THEN 20 WHEN N'Warning' THEN 10 WHEN N'Unknown' THEN 5 ELSE 0 END
               - CASE b.DeadlockHealth WHEN N'Critical' THEN 15 WHEN N'Warning' THEN 8 WHEN N'Unknown' THEN 0 ELSE 0 END
               - CASE b.BackupHealth WHEN N'Critical' THEN 25 WHEN N'Warning' THEN 10 WHEN N'Unknown' THEN 5 ELSE 0 END
               - CASE b.ConfigurationHealth WHEN N'Critical' THEN 10 WHEN N'Warning' THEN 5 WHEN N'Unknown' THEN 3 ELSE 0 END
               - CASE b.FreshnessHealth WHEN N'Critical' THEN 25 WHEN N'Warning' THEN 15 WHEN N'Unknown' THEN 10 ELSE 0 END
               - CASE WHEN b.CollectorCriticalCount > 0 THEN 25 WHEN b.CollectorWarningCount > 0 THEN 10 ELSE 0 END
        END),
    OverallHealth = CASE
        WHEN b.CollectorCriticalCount > 0 THEN N'Critical'
        WHEN b.FreshnessHealth = N'Critical' THEN N'Critical'
        WHEN b.CpuHealth = N'Critical' THEN N'Critical'
        WHEN b.MemoryHealth = N'Critical' THEN N'Critical'
        WHEN b.BlockingHealth = N'Critical' THEN N'Critical'
        WHEN b.DeadlockHealth = N'Critical' THEN N'Critical'
        WHEN b.BackupHealth = N'Critical' THEN N'Critical'
        WHEN b.CollectorWarningCount > 0 THEN N'Warning'
        WHEN b.FreshnessHealth IN (N'Warning',N'Unknown') THEN N'Warning'
        WHEN b.CpuHealth IN (N'Warning',N'Unknown') THEN N'Warning'
        WHEN b.MemoryHealth IN (N'Warning',N'Unknown') THEN N'Warning'
        WHEN b.BlockingHealth IN (N'Warning',N'Unknown') THEN N'Warning'
        WHEN b.DeadlockHealth = N'Warning' THEN N'Warning'
        WHEN b.BackupHealth IN (N'Warning',N'Unknown') THEN N'Warning'
        WHEN b.ConfigurationHealth IN (N'Warning',N'Unknown') THEN N'Warning'
        ELSE N'Healthy'
    END
FROM Base AS b;
GO

PRINT 'SQLSentinel consolidated server health scorecard view created/updated.';
GO
