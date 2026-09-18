USE SQLMonitoring;
GO

IF SCHEMA_ID(N'rpt') IS NULL
    EXEC(N'CREATE SCHEMA rpt AUTHORIZATION dbo;');
GO

/*=============================================================================
  SQLSentinel - rpt Reporting Layer

  Deployment order is dependency-safe:

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
=============================================================================*/

/*=============================================================================
  01. Instance Inventory
=============================================================================*/
CREATE OR ALTER VIEW rpt.vw_InstanceInventory
AS
SELECT
    mi.InstanceId,
    mi.InstanceName,
    mi.EnvironmentName,
    mi.IsEnabled,
    mi.CollectionProfile,
    mi.ComplianceProfile,
    mi.SqlVersion,
    mi.Edition,
    mi.CreatedAt,
    mi.ModifiedAt,
    mi.Notes
FROM dbo.MonitoredInstances AS mi;
GO

/*=============================================================================
  02. Latest Metric
=============================================================================*/
CREATE OR ALTER VIEW rpt.vw_MetricLatest
AS
WITH Ranked AS
(
    SELECT
        ms.InstanceId,
        ms.CaptureTime,
        ms.DatabaseName,
        ms.ObjectName,
        ms.CounterName,
        ms.InstanceName AS CounterInstanceName,
        ms.MetricCategory,
        ms.MetricValue,
        ms.MetricType,
        ms.Unit,
        ms.SourceCollector,
        rn = ROW_NUMBER() OVER
        (
            PARTITION BY
                ms.InstanceId,
                ISNULL(ms.DatabaseName,N''),
                ISNULL(ms.ObjectName,N''),
                ISNULL(ms.CounterName,N''),
                ISNULL(ms.InstanceName,N''),
                ISNULL(ms.MetricCategory,N''),
                ISNULL(ms.SourceCollector,N'')
            ORDER BY ms.CaptureTime DESC
        )
    FROM dbo.MetricSnapshot AS ms
)
SELECT
    r.InstanceId,
    mi.InstanceName,
    mi.EnvironmentName,
    mi.CollectionProfile,
    mi.ComplianceProfile,
    r.CaptureTime,
    r.DatabaseName,
    r.ObjectName,
    r.CounterName,
    r.CounterInstanceName,
    r.MetricCategory,
    r.MetricValue,
    r.MetricType,
    r.Unit,
    r.SourceCollector
FROM Ranked AS r
INNER JOIN dbo.MonitoredInstances AS mi
    ON mi.InstanceId = r.InstanceId
WHERE r.rn = 1;
GO

/*=============================================================================
  03. Metric Trend
=============================================================================*/
CREATE OR ALTER VIEW rpt.vw_MetricTrend
AS
SELECT
    ms.InstanceId,
    mi.InstanceName,
    mi.EnvironmentName,
    mi.CollectionProfile,
    mi.ComplianceProfile,
    ms.CaptureTime,
    ms.DatabaseName,
    ms.ObjectName,
    ms.CounterName,
    ms.InstanceName AS CounterInstanceName,
    ms.MetricCategory,
    ms.MetricValue,
    ms.MetricType,
    ms.Unit,
    ms.SourceCollector
FROM dbo.MetricSnapshot AS ms
INNER JOIN dbo.MonitoredInstances AS mi
    ON mi.InstanceId = ms.InstanceId;
GO

/*=============================================================================
  04. Repository Health
=============================================================================*/
CREATE OR ALTER VIEW rpt.vw_RepositoryHealth
AS
SELECT
    DatabaseName = DB_NAME(),
    DataSizeMB = CAST
    (
        SUM(CASE WHEN df.type = 0 THEN df.size ELSE 0 END)
        * 8.0 / 1024.0 AS decimal(19,2)
    ),
    LogSizeMB = CAST
    (
        SUM(CASE WHEN df.type = 1 THEN df.size ELSE 0 END)
        * 8.0 / 1024.0 AS decimal(19,2)
    ),
    TotalAllocatedMB = CAST
    (
        SUM(df.size) * 8.0 / 1024.0 AS decimal(19,2)
    ),
    DataFileCount = SUM(CASE WHEN df.type = 0 THEN 1 ELSE 0 END),
    LogFileCount = SUM(CASE WHEN df.type = 1 THEN 1 ELSE 0 END),
    CaptureTime = SYSDATETIME()
FROM sys.database_files AS df;
GO

/*=============================================================================
  05. Collector Health
=============================================================================*/
CREATE OR ALTER VIEW rpt.vw_CollectorHealth
AS
WITH LastRun AS
(
    SELECT
        crh.InstanceId,
        crh.CollectorName,
        crh.StartedAt,
        crh.FinishedAt,
        crh.Status,
        crh.RowsCollected,
        crh.DurationMs,
        crh.ErrorMessage,
        rn = ROW_NUMBER() OVER
        (
            PARTITION BY crh.InstanceId, crh.CollectorName
            ORDER BY crh.StartedAt DESC, crh.CollectionRunId DESC
        )
    FROM dbo.CollectionRunHistory AS crh
)
SELECT
    mi.InstanceId,
    mi.InstanceName,
    mi.EnvironmentName,
    lr.CollectorName,
    lr.StartedAt AS LastStartedAt,
    lr.FinishedAt AS LastFinishedAt,
    lr.Status AS LastStatus,
    lr.RowsCollected,
    lr.DurationMs,
    lr.ErrorMessage,
    HoursSinceLastRun =
        DATEDIFF(MINUTE, lr.StartedAt, SYSDATETIME()) / 60.0,
    CollectorHealth =
        CASE
            WHEN lr.Status IS NULL THEN N'Unknown'
            WHEN lr.Status IN (N'Failed',N'Error') THEN N'Critical'
            WHEN lr.Status = N'Running'
             AND lr.StartedAt < DATEADD(MINUTE,-30,SYSDATETIME())
                THEN N'Warning'
            WHEN lr.StartedAt < DATEADD(HOUR,-24,SYSDATETIME())
                THEN N'Warning'
            WHEN lr.Status IN (N'Success',N'Succeeded',N'Completed')
                THEN N'Healthy'
            ELSE N'Warning'
        END
FROM dbo.MonitoredInstances AS mi
LEFT JOIN LastRun AS lr
    ON lr.InstanceId = mi.InstanceId
   AND lr.rn = 1
WHERE mi.IsEnabled = 1;
GO

/*=============================================================================
  06. Data Freshness Current
=============================================================================*/
CREATE OR ALTER VIEW rpt.vw_DataFreshnessCurrent
AS
WITH C AS
(
    SELECT
        InstanceId,
        CollectorName,
        MAX(StartedAt) AS LastStartedAt,
        MAX
        (
            CASE
                WHEN Status IN(N'Success',N'Succeeded',N'Completed')
                THEN FinishedAt
            END
        ) AS LastSuccessfulAt
    FROM dbo.CollectionRunHistory
    GROUP BY InstanceId, CollectorName
),
S AS
(
    SELECT
        InstanceId,
        MAX(LastStartedAt) AS LastCollectionAttempt,
        MIN(LastSuccessfulAt) AS OldestCollectorSuccess,
        MAX(LastSuccessfulAt) AS LatestCollectorSuccess,
        SUM(CASE WHEN LastSuccessfulAt IS NULL THEN 1 ELSE 0 END)
            AS CollectorsNeverSuccessful
    FROM C
    GROUP BY InstanceId
)
SELECT
    mi.InstanceId,
    mi.InstanceName,
    mi.EnvironmentName,
    s.LastCollectionAttempt,
    s.OldestCollectorSuccess,
    s.LatestCollectorSuccess,
    ISNULL(s.CollectorsNeverSuccessful,0) AS CollectorsNeverSuccessful,
    FreshnessHealth =
        CASE
            WHEN s.InstanceId IS NULL THEN N'Unknown'
            WHEN ISNULL(s.CollectorsNeverSuccessful,0) > 0 THEN N'Warning'
            WHEN s.OldestCollectorSuccess < DATEADD(HOUR,-24,SYSDATETIME())
                THEN N'Warning'
            ELSE N'Healthy'
        END
FROM dbo.MonitoredInstances AS mi
LEFT JOIN S AS s
    ON s.InstanceId = mi.InstanceId
WHERE mi.IsEnabled = 1;
GO

/*=============================================================================
  07. Backup Compliance Current
=============================================================================*/
CREATE OR ALTER VIEW rpt.vw_BackupComplianceCurrent
AS
WITH LatestCapture AS
(
    SELECT
        ms.InstanceId,
        MAX(ms.CaptureTime) AS CaptureTime
    FROM dbo.MetricSnapshot AS ms
    WHERE ms.SourceCollector = N'Collect-Backups'
      AND ms.MetricCategory = N'BackupCompliance'
      AND ms.ObjectName = N'BackupComplianceSummary'
    GROUP BY ms.InstanceId
),
BackupSummary AS
(
    SELECT
        ms.InstanceId,
        ms.CaptureTime,
        MAX(CASE WHEN ms.CounterName = N'DatabaseCount'
                 THEN ms.MetricValue END) AS DatabaseCount,
        MAX(CASE WHEN ms.CounterName = N'DatabasesWithoutFullBackup'
                 THEN ms.MetricValue END) AS DatabasesWithoutFullBackup,
        MAX(CASE WHEN ms.CounterName = N'DatabasesWithOldFullBackup'
                 THEN ms.MetricValue END) AS DatabasesWithOldFullBackup,
        MAX(CASE WHEN ms.CounterName = N'DatabasesWithOldDiffBackup'
                 THEN ms.MetricValue END) AS DatabasesWithOldDiffBackup,
        MAX(CASE WHEN ms.CounterName = N'RecoveryModelViolations'
                 THEN ms.MetricValue END) AS RecoveryModelViolations,
        MAX(CASE WHEN ms.CounterName = N'DatabasesWithoutRequiredLogBackup'
                 THEN ms.MetricValue END) AS DatabasesWithoutRequiredLogBackup,
        MAX(CASE WHEN ms.CounterName = N'DatabasesWithOldRequiredLogBackup'
                 THEN ms.MetricValue END) AS DatabasesWithOldRequiredLogBackup,
        MAX(CASE WHEN ms.CounterName = N'NonCompliantDatabaseCount'
                 THEN ms.MetricValue END) AS NonCompliantDatabaseCount,
        MAX(CASE WHEN ms.CounterName = N'MaxFullBackupAgeHours'
                 THEN ms.MetricValue END) AS MaxFullBackupAgeHours,
        MAX(CASE WHEN ms.CounterName = N'MaxLogBackupAgeHours'
                 THEN ms.MetricValue END) AS MaxLogBackupAgeHours
    FROM dbo.MetricSnapshot AS ms
    INNER JOIN LatestCapture AS lc
        ON lc.InstanceId = ms.InstanceId
       AND lc.CaptureTime = ms.CaptureTime
    WHERE ms.SourceCollector = N'Collect-Backups'
      AND ms.MetricCategory = N'BackupCompliance'
      AND ms.ObjectName = N'BackupComplianceSummary'
    GROUP BY ms.InstanceId, ms.CaptureTime
)
SELECT
    mi.InstanceId,
    mi.InstanceName,
    mi.EnvironmentName,
    mi.ComplianceProfile,
    bs.CaptureTime,
    bs.DatabaseCount,
    bs.DatabasesWithoutFullBackup,
    bs.DatabasesWithOldFullBackup,
    bs.DatabasesWithOldDiffBackup,
    bs.RecoveryModelViolations,
    bs.DatabasesWithoutRequiredLogBackup,
    bs.DatabasesWithOldRequiredLogBackup,
    bs.NonCompliantDatabaseCount,
    bs.MaxFullBackupAgeHours,
    bs.MaxLogBackupAgeHours,
    BackupProtectionIssueCount =
          ISNULL(bs.DatabasesWithoutFullBackup,0)
        + ISNULL(bs.DatabasesWithOldFullBackup,0)
        + ISNULL(bs.DatabasesWithOldDiffBackup,0)
        + ISNULL(bs.DatabasesWithoutRequiredLogBackup,0)
        + ISNULL(bs.DatabasesWithOldRequiredLogBackup,0),
    ConfigurationViolationCount =
        ISNULL(bs.RecoveryModelViolations,0),
    BackupHealth =
        CASE
            WHEN bs.InstanceId IS NULL THEN N'Unknown'
            WHEN ISNULL(bs.DatabasesWithoutFullBackup,0) > 0
              OR ISNULL(bs.DatabasesWithOldFullBackup,0) > 0
              OR ISNULL(bs.DatabasesWithOldDiffBackup,0) > 0
              OR ISNULL(bs.DatabasesWithoutRequiredLogBackup,0) > 0
              OR ISNULL(bs.DatabasesWithOldRequiredLogBackup,0) > 0
                THEN N'Critical'
            ELSE N'Healthy'
        END,
    ConfigurationHealth =
        CASE
            WHEN bs.InstanceId IS NULL THEN N'Unknown'
            WHEN ISNULL(bs.RecoveryModelViolations,0) > 0
                THEN N'Warning'
            ELSE N'Healthy'
        END
FROM dbo.MonitoredInstances AS mi
LEFT JOIN BackupSummary AS bs
    ON bs.InstanceId = mi.InstanceId
WHERE mi.IsEnabled = 1;
GO

/*=============================================================================
  08. Blocking Health Current
=============================================================================*/
CREATE OR ALTER VIEW rpt.vw_BlockingHealthCurrent
AS
WITH L AS
(
    SELECT
        ms.*,
        ROW_NUMBER() OVER
        (
            PARTITION BY ms.InstanceId, ms.CounterName
            ORDER BY ms.CaptureTime DESC
        ) AS rn
    FROM dbo.MetricSnapshot AS ms
    WHERE ms.SourceCollector = N'Collect-Blocking'
      AND ms.ObjectName = N'BlockingSummary'
),
B AS
(
    SELECT
        InstanceId,
        MAX(CaptureTime) AS CaptureTime,
        MAX(CASE WHEN CounterName=N'BlockedSessionCount'
                 THEN MetricValue END) AS BlockedSessionCount,
        MAX(CASE WHEN CounterName=N'DistinctBlockingSessionCount'
                 THEN MetricValue END) AS DistinctBlockingSessionCount,
        MAX(CASE WHEN CounterName=N'MaxWaitSeconds'
                 THEN MetricValue END) AS MaxWaitSeconds,
        MAX(CASE WHEN CounterName=N'TotalWaitSeconds'
                 THEN MetricValue END) AS TotalWaitSeconds
    FROM L
    WHERE rn = 1
    GROUP BY InstanceId
)
SELECT
    mi.InstanceId,
    mi.InstanceName,
    mi.EnvironmentName,
    b.CaptureTime,
    b.BlockedSessionCount,
    b.DistinctBlockingSessionCount,
    b.MaxWaitSeconds,
    b.TotalWaitSeconds,
    BlockingHealth =
        CASE
            WHEN b.InstanceId IS NULL THEN N'Unknown'
            WHEN ISNULL(b.MaxWaitSeconds,0) >= 60
              OR ISNULL(b.BlockedSessionCount,0) >= 5
                THEN N'Critical'
            WHEN ISNULL(b.BlockedSessionCount,0) > 0
                THEN N'Warning'
            ELSE N'Healthy'
        END
FROM dbo.MonitoredInstances AS mi
LEFT JOIN B AS b
    ON b.InstanceId = mi.InstanceId
WHERE mi.IsEnabled = 1;
GO

/*=============================================================================
  09. Performance Health Current
=============================================================================*/
CREATE OR ALTER VIEW rpt.vw_PerformanceHealthCurrent
AS
WITH Ranked AS
(
    SELECT
        ms.InstanceId,
        ms.CaptureTime,
        ms.CounterName,
        ms.MetricValue,
        rn = ROW_NUMBER() OVER
        (
            PARTITION BY ms.InstanceId, ms.CounterName
            ORDER BY ms.CaptureTime DESC
        ),
        PreviousMetricValue = LAG(ms.MetricValue) OVER
        (
            PARTITION BY ms.InstanceId, ms.CounterName
            ORDER BY ms.CaptureTime
        )
    FROM dbo.MetricSnapshot AS ms
    WHERE ms.SourceCollector = N'Collect-PerformanceCounters'
      AND ms.CounterName IN
      (
        N'Memory Grants Pending',
        N'Target Server Memory (KB)',
        N'Total Server Memory (KB)',
        N'Page life expectancy',
        N'Number of Deadlocks/sec',
        N'SqlProcessCpuPercent',
        N'SystemCpuPercent',
        N'SystemIdlePercent'
      )
),
P AS
(
    SELECT
        InstanceId,
        MAX(CaptureTime) AS CaptureTime,
        MAX(CASE WHEN CounterName=N'Memory Grants Pending' AND rn=1
                 THEN MetricValue END) AS MemoryGrantsPending,
        MAX(CASE WHEN CounterName=N'Target Server Memory (KB)' AND rn=1
                 THEN MetricValue END) AS TargetServerMemoryKB,
        MAX(CASE WHEN CounterName=N'Total Server Memory (KB)' AND rn=1
                 THEN MetricValue END) AS TotalServerMemoryKB,
        MAX(CASE WHEN CounterName=N'Page life expectancy' AND rn=1
                 THEN MetricValue END) AS PageLifeExpectancySeconds,
        MAX(CASE WHEN CounterName=N'Number of Deadlocks/sec' AND rn=1
                 THEN MetricValue END) AS DeadlockCounter,
        MAX(CASE WHEN CounterName=N'Number of Deadlocks/sec' AND rn=1
                 THEN PreviousMetricValue END) AS PreviousDeadlockCounter,
        MAX(CASE WHEN CounterName=N'SqlProcessCpuPercent' AND rn=1
                 THEN MetricValue END) AS SqlProcessCpuPercent,
        MAX(CASE WHEN CounterName=N'SystemCpuPercent' AND rn=1
                 THEN MetricValue END) AS SystemCpuPercent,
        MAX(CASE WHEN CounterName=N'SystemIdlePercent' AND rn=1
                 THEN MetricValue END) AS SystemIdlePercent
    FROM Ranked
    GROUP BY InstanceId
)
SELECT
    mi.InstanceId,
    mi.InstanceName,
    mi.EnvironmentName,
    p.CaptureTime,
    p.SqlProcessCpuPercent,
    p.SystemCpuPercent,
    p.SystemIdlePercent,
    p.MemoryGrantsPending,
    p.TargetServerMemoryKB,
    p.TotalServerMemoryKB,
    p.PageLifeExpectancySeconds,
    p.DeadlockCounter,
    DeadlocksSincePreviousSample =
        CASE
            WHEN p.DeadlockCounter IS NULL
              OR p.PreviousDeadlockCounter IS NULL
                THEN NULL
            WHEN p.DeadlockCounter < p.PreviousDeadlockCounter
                THEN NULL
            ELSE p.DeadlockCounter - p.PreviousDeadlockCounter
        END,
    CpuHealth =
        CASE
            WHEN p.InstanceId IS NULL
              OR p.SystemCpuPercent IS NULL
                THEN N'Unknown'
            WHEN p.SystemCpuPercent >= 90
              OR p.SqlProcessCpuPercent >= 85
                THEN N'Critical'
            WHEN p.SystemCpuPercent >= 80
              OR p.SqlProcessCpuPercent >= 70
                THEN N'Warning'
            ELSE N'Healthy'
        END,
    MemoryHealth =
        CASE
            WHEN p.InstanceId IS NULL THEN N'Unknown'
            WHEN ISNULL(p.MemoryGrantsPending,0) >= 5 THEN N'Critical'
            WHEN ISNULL(p.MemoryGrantsPending,0) > 0 THEN N'Warning'
            ELSE N'Healthy'
        END,
    DeadlockHealth =
        CASE
            WHEN p.InstanceId IS NULL
              OR p.DeadlockCounter IS NULL
                THEN N'Unknown'
            WHEN p.PreviousDeadlockCounter IS NULL
                THEN N'Unknown'
            WHEN p.DeadlockCounter < p.PreviousDeadlockCounter
                THEN N'Unknown'
            WHEN p.DeadlockCounter - p.PreviousDeadlockCounter >= 5
                THEN N'Critical'
            WHEN p.DeadlockCounter - p.PreviousDeadlockCounter > 0
                THEN N'Warning'
            ELSE N'Healthy'
        END
FROM dbo.MonitoredInstances AS mi
LEFT JOIN P AS p
    ON p.InstanceId = mi.InstanceId
WHERE mi.IsEnabled = 1;
GO

/*=============================================================================
  10. Query Pressure Current
=============================================================================*/
CREATE OR ALTER VIEW rpt.vw_QueryPressureCurrent
AS
WITH L AS
(
    SELECT
        ms.*,
        ROW_NUMBER() OVER
        (
            PARTITION BY ms.InstanceId, ms.CounterName
            ORDER BY ms.CaptureTime DESC
        ) AS rn
    FROM dbo.MetricSnapshot AS ms
    WHERE ms.SourceCollector=N'Collect-QueryStats'
      AND ms.ObjectName=N'QueryStatsSummary'
),
Q AS
(
    SELECT
        InstanceId,
        MAX(CaptureTime) AS CaptureTime,
        MAX(CASE WHEN CounterName=N'TopCpuQueryCount'
                 THEN MetricValue END) AS TopCpuQueryCount,
        MAX(CASE WHEN CounterName=N'TopDurationQueryCount'
                 THEN MetricValue END) AS TopDurationQueryCount,
        MAX(CASE WHEN CounterName=N'TopLogicalReadQueryCount'
                 THEN MetricValue END) AS TopLogicalReadQueryCount,
        MAX(CASE WHEN CounterName=N'TopExecutionQueryCount'
                 THEN MetricValue END) AS TopExecutionQueryCount,
        MAX(CASE WHEN CounterName=N'DistinctQueriesCaptured'
                 THEN MetricValue END) AS DistinctQueriesCaptured
    FROM L
    WHERE rn=1
    GROUP BY InstanceId
)
SELECT
    mi.InstanceId,
    mi.InstanceName,
    mi.EnvironmentName,
    q.CaptureTime,
    q.TopCpuQueryCount,
    q.TopDurationQueryCount,
    q.TopLogicalReadQueryCount,
    q.TopExecutionQueryCount,
    q.DistinctQueriesCaptured,
    QueryDataHealth =
        CASE
            WHEN q.InstanceId IS NULL THEN N'Unknown'
            ELSE N'Available'
        END
FROM dbo.MonitoredInstances AS mi
LEFT JOIN Q AS q
    ON q.InstanceId = mi.InstanceId
WHERE mi.IsEnabled = 1;
GO

/*=============================================================================
  11. SQL Agent Health Current
=============================================================================*/
CREATE OR ALTER VIEW rpt.vw_SQLAgentHealthCurrent
AS
WITH L AS
(
    SELECT
        ms.*,
        ROW_NUMBER() OVER
        (
            PARTITION BY ms.InstanceId, ms.CounterName
            ORDER BY ms.CaptureTime DESC
        ) AS rn
    FROM dbo.MetricSnapshot AS ms
    WHERE ms.SourceCollector=N'Collect-SqlAgentJobs'
      AND ms.MetricCategory=N'SqlAgentJob'
      AND ms.ObjectName=N'SqlAgentJobSummary'
),
A AS
(
    SELECT
        InstanceId,
        MAX(CaptureTime) AS CaptureTime,
        MAX(CASE WHEN CounterName=N'RecentFailedJobs'
                 THEN MetricValue END) AS RecentFailedJobs,
        MAX(CASE WHEN CounterName=N'RecentCanceledJobs'
                 THEN MetricValue END) AS RecentCanceledJobs,
        MAX(CASE WHEN CounterName=N'RecentRetryJobs'
                 THEN MetricValue END) AS RecentRetryJobs,
        MAX(CASE WHEN CounterName=N'RecentSucceededJobs'
                 THEN MetricValue END) AS RecentSucceededJobs,
        MAX(CASE WHEN CounterName=N'RecentCompletedJobs'
                 THEN MetricValue END) AS RecentCompletedJobs,
        MAX(CASE WHEN CounterName=N'TotalEnabledJobs'
                 THEN MetricValue END) AS TotalEnabledJobs,
        MAX(CASE WHEN CounterName=N'TotalDisabledJobs'
                 THEN MetricValue END) AS TotalDisabledJobs,
        MAX(CASE WHEN CounterName=N'RunningJobCount'
                 THEN MetricValue END) AS RunningJobCount,
        MAX(CASE WHEN CounterName=N'MaxRunningSeconds'
                 THEN MetricValue END) AS MaxRunningSeconds,
        MAX(CASE WHEN CounterName=N'MaxRunDurationSeconds'
                 THEN MetricValue END) AS MaxRunDurationSeconds,
        MAX(CASE WHEN CounterName=N'AvgRunDurationSeconds'
                 THEN MetricValue END) AS AvgRunDurationSeconds
    FROM L
    WHERE rn=1
    GROUP BY InstanceId
)
SELECT
    mi.InstanceId,
    mi.InstanceName,
    mi.EnvironmentName,
    a.CaptureTime,
    a.RecentFailedJobs,
    a.RecentCanceledJobs,
    a.RecentRetryJobs,
    a.RecentSucceededJobs,
    a.RecentCompletedJobs,
    a.TotalEnabledJobs,
    a.TotalDisabledJobs,
    a.RunningJobCount,
    a.MaxRunningSeconds,
    a.MaxRunDurationSeconds,
    a.AvgRunDurationSeconds,
    SQLAgentHealth =
        CASE
            WHEN a.InstanceId IS NULL
              OR a.RecentFailedJobs IS NULL
                THEN N'Unknown'
            WHEN a.RecentFailedJobs > 0
                THEN N'Critical'
            WHEN ISNULL(a.RecentCanceledJobs,0) > 0
              OR ISNULL(a.RecentRetryJobs,0) > 0
                THEN N'Warning'
            ELSE N'Healthy'
        END
FROM dbo.MonitoredInstances AS mi
LEFT JOIN A AS a
    ON a.InstanceId = mi.InstanceId
WHERE mi.IsEnabled = 1;
GO

/*=============================================================================
  12. Wait Pressure Current

  NOTE: This is synchronized from the current SQLMonitoring definition.
  The wait-sample interval behavior should be reviewed separately.
=============================================================================*/
CREATE OR ALTER VIEW rpt.vw_WaitPressureCurrent
AS
WITH Captures AS
(
    SELECT
        InstanceId,
        CaptureTime,
        DENSE_RANK() OVER
        (
            PARTITION BY InstanceId
            ORDER BY CaptureTime DESC
        ) AS CaptureRank
    FROM dbo.MetricSnapshot
    WHERE SourceCollector=N'Collect-WaitStats'
      AND ObjectName=N'SQLWaitStats'
    GROUP BY InstanceId,CaptureTime
),
CaptureWindow AS
(
    SELECT
        InstanceId,
        MAX(CASE WHEN CaptureRank=1 THEN CaptureTime END)
            AS CurrentCaptureTime,
        MAX(CASE WHEN CaptureRank=2 THEN CaptureTime END)
            AS PreviousCaptureTime
    FROM Captures
    WHERE CaptureRank<=2
    GROUP BY InstanceId
),
W AS
(
    SELECT
        ms.InstanceId,
        ms.CaptureTime,
        ms.InstanceName AS WaitType,
        ms.CounterName,
        ms.MetricValue,
        c.CaptureRank
    FROM dbo.MetricSnapshot AS ms
    JOIN Captures AS c
      ON c.InstanceId=ms.InstanceId
     AND c.CaptureTime=ms.CaptureTime
    WHERE ms.SourceCollector=N'Collect-WaitStats'
      AND ms.ObjectName=N'SQLWaitStats'
      AND c.CaptureRank<=2
),
D AS
(
    SELECT
        cur.InstanceId,
        cur.CaptureTime,
        cur.WaitType,
        WaitTimeDeltaMs =
            CASE
                WHEN prev.MetricValue IS NULL
                  OR cur.MetricValue < prev.MetricValue
                    THEN NULL
                ELSE cur.MetricValue-prev.MetricValue
            END
    FROM W AS cur
    LEFT JOIN W AS prev
      ON prev.InstanceId=cur.InstanceId
     AND prev.WaitType=cur.WaitType
     AND prev.CounterName=cur.CounterName
     AND prev.CaptureRank=2
    WHERE cur.CaptureRank=1
      AND cur.CounterName=N'WaitTimeMs'
),
R AS
(
    SELECT
        *,
        WaitCategory =
            CASE
                WHEN WaitType LIKE N'LCK[_]%' THEN N'Locking'
                WHEN WaitType IN
                (
                    N'PAGEIOLATCH_SH',N'PAGEIOLATCH_EX',N'PAGEIOLATCH_UP',
                    N'IO_COMPLETION',N'ASYNC_IO_COMPLETION'
                ) THEN N'IO'
                WHEN WaitType IN(N'CXPACKET',N'CXCONSUMER')
                    THEN N'Parallelism'
                WHEN WaitType IN(N'RESOURCE_SEMAPHORE',N'CMEMTHREAD')
                    THEN N'Memory'
                WHEN WaitType IN(N'SOS_SCHEDULER_YIELD',N'THREADPOOL')
                    THEN N'CPU'
                WHEN WaitType LIKE N'WRITELOG%' THEN N'LogIO'
                ELSE N'Other'
            END
    FROM D
),
A AS
(
    SELECT
        r.InstanceId,
        MAX(r.CaptureTime) AS CaptureTime,
        SUM(ISNULL(r.WaitTimeDeltaMs,0)) AS TotalWaitDeltaMs,
        SUM(CASE WHEN r.WaitCategory=N'Locking'
                 THEN ISNULL(r.WaitTimeDeltaMs,0) ELSE 0 END)
            AS LockWaitDeltaMs,
        SUM(CASE WHEN r.WaitCategory=N'IO'
                 THEN ISNULL(r.WaitTimeDeltaMs,0) ELSE 0 END)
            AS IOWaitDeltaMs,
        SUM(CASE WHEN r.WaitCategory=N'Parallelism'
                 THEN ISNULL(r.WaitTimeDeltaMs,0) ELSE 0 END)
            AS ParallelismWaitDeltaMs,
        SUM(CASE WHEN r.WaitCategory=N'Memory'
                 THEN ISNULL(r.WaitTimeDeltaMs,0) ELSE 0 END)
            AS MemoryWaitDeltaMs,
        SUM(CASE WHEN r.WaitCategory=N'CPU'
                 THEN ISNULL(r.WaitTimeDeltaMs,0) ELSE 0 END)
            AS CPUWaitDeltaMs,
        SUM(CASE WHEN r.WaitCategory=N'LogIO'
                 THEN ISNULL(r.WaitTimeDeltaMs,0) ELSE 0 END)
            AS LogIOWaitDeltaMs,
        SUM(CASE WHEN r.WaitTimeDeltaMs IS NULL THEN 1 ELSE 0 END)
            AS WaitTypesWithoutBaseline,
        SampleIntervalSeconds =
            DATEDIFF(SECOND,cw.PreviousCaptureTime,cw.CurrentCaptureTime)
    FROM R AS r
    JOIN CaptureWindow AS cw
      ON cw.InstanceId=r.InstanceId
    GROUP BY
        r.InstanceId,
        cw.PreviousCaptureTime,
        cw.CurrentCaptureTime
),
N AS
(
    SELECT
        *,
        TotalWaitMsPerSecond =
            CONVERT
            (
                decimal(19,2),
                TotalWaitDeltaMs
                / NULLIF(CONVERT(decimal(19,4),SampleIntervalSeconds),0)
            ),
        LockWaitMsPerSecond =
            CONVERT
            (
                decimal(19,2),
                LockWaitDeltaMs
                / NULLIF(CONVERT(decimal(19,4),SampleIntervalSeconds),0)
            ),
        IOWaitMsPerSecond =
            CONVERT
            (
                decimal(19,2),
                IOWaitDeltaMs
                / NULLIF(CONVERT(decimal(19,4),SampleIntervalSeconds),0)
            ),
        ParallelismWaitMsPerSecond =
            CONVERT
            (
                decimal(19,2),
                ParallelismWaitDeltaMs
                / NULLIF(CONVERT(decimal(19,4),SampleIntervalSeconds),0)
            ),
        MemoryWaitMsPerSecond =
            CONVERT
            (
                decimal(19,2),
                MemoryWaitDeltaMs
                / NULLIF(CONVERT(decimal(19,4),SampleIntervalSeconds),0)
            ),
        CPUWaitMsPerSecond =
            CONVERT
            (
                decimal(19,2),
                CPUWaitDeltaMs
                / NULLIF(CONVERT(decimal(19,4),SampleIntervalSeconds),0)
            ),
        LogIOWaitMsPerSecond =
            CONVERT
            (
                decimal(19,2),
                LogIOWaitDeltaMs
                / NULLIF(CONVERT(decimal(19,4),SampleIntervalSeconds),0)
            )
    FROM A
)
SELECT
    mi.InstanceId,
    mi.InstanceName,
    mi.EnvironmentName,
    n.CaptureTime,
    n.SampleIntervalSeconds,
    n.TotalWaitDeltaMs,
    n.LockWaitDeltaMs,
    n.IOWaitDeltaMs,
    n.ParallelismWaitDeltaMs,
    n.MemoryWaitDeltaMs,
    n.CPUWaitDeltaMs,
    n.LogIOWaitDeltaMs,
    n.TotalWaitMsPerSecond,
    n.LockWaitMsPerSecond,
    n.IOWaitMsPerSecond,
    n.ParallelismWaitMsPerSecond,
    n.MemoryWaitMsPerSecond,
    n.CPUWaitMsPerSecond,
    n.LogIOWaitMsPerSecond,
    n.WaitTypesWithoutBaseline,
    DominantWaitCategory =
        CASE
            WHEN n.InstanceId IS NULL THEN N'Unknown'
            WHEN n.LockWaitDeltaMs>=n.IOWaitDeltaMs
             AND n.LockWaitDeltaMs>=n.ParallelismWaitDeltaMs
             AND n.LockWaitDeltaMs>=n.MemoryWaitDeltaMs
             AND n.LockWaitDeltaMs>=n.CPUWaitDeltaMs
             AND n.LockWaitDeltaMs>=n.LogIOWaitDeltaMs
             AND n.LockWaitDeltaMs>0
                THEN N'Locking'
            WHEN n.IOWaitDeltaMs>=n.ParallelismWaitDeltaMs
             AND n.IOWaitDeltaMs>=n.MemoryWaitDeltaMs
             AND n.IOWaitDeltaMs>=n.CPUWaitDeltaMs
             AND n.IOWaitDeltaMs>=n.LogIOWaitDeltaMs
             AND n.IOWaitDeltaMs>0
                THEN N'IO'
            WHEN n.ParallelismWaitDeltaMs>=n.MemoryWaitDeltaMs
             AND n.ParallelismWaitDeltaMs>=n.CPUWaitDeltaMs
             AND n.ParallelismWaitDeltaMs>=n.LogIOWaitDeltaMs
             AND n.ParallelismWaitDeltaMs>0
                THEN N'Parallelism'
            WHEN n.MemoryWaitDeltaMs>=n.CPUWaitDeltaMs
             AND n.MemoryWaitDeltaMs>=n.LogIOWaitDeltaMs
             AND n.MemoryWaitDeltaMs>0
                THEN N'Memory'
            WHEN n.CPUWaitDeltaMs>=n.LogIOWaitDeltaMs
             AND n.CPUWaitDeltaMs>0
                THEN N'CPU'
            WHEN n.LogIOWaitDeltaMs>0
                THEN N'LogIO'
            ELSE N'None'
        END,
    WaitHealth =
        CASE
            WHEN n.InstanceId IS NULL
              OR n.SampleIntervalSeconds IS NULL
              OR n.SampleIntervalSeconds<=0
                THEN N'Unknown'
            WHEN n.WaitTypesWithoutBaseline>0
             AND n.TotalWaitDeltaMs=0
                THEN N'Unknown'
            WHEN n.LockWaitMsPerSecond>=100
              OR n.MemoryWaitMsPerSecond>=100
              OR n.CPUWaitMsPerSecond>=500
              OR n.IOWaitMsPerSecond>=500
              OR n.LogIOWaitMsPerSecond>=500
                THEN N'Critical'
            WHEN n.LockWaitMsPerSecond>=20
              OR n.MemoryWaitMsPerSecond>=20
              OR n.CPUWaitMsPerSecond>=100
              OR n.IOWaitMsPerSecond>=100
              OR n.LogIOWaitMsPerSecond>=100
              OR n.ParallelismWaitMsPerSecond>=500
                THEN N'Warning'
            ELSE N'Healthy'
        END
FROM dbo.MonitoredInstances AS mi
LEFT JOIN N AS n
    ON n.InstanceId=mi.InstanceId
WHERE mi.IsEnabled=1;
GO

/*=============================================================================
  13. Server Health Current
=============================================================================*/
CREATE OR ALTER VIEW rpt.vw_ServerHealthCurrent
AS
WITH CollectorSummary AS
(
    SELECT
        ch.InstanceId,
        CollectorCriticalCount =
            SUM(CASE WHEN ch.CollectorHealth=N'Critical' THEN 1 ELSE 0 END),
        CollectorWarningCount =
            SUM(CASE WHEN ch.CollectorHealth=N'Warning' THEN 1 ELSE 0 END),
        LastCollectionTime = MAX(ch.LastStartedAt)
    FROM rpt.vw_CollectorHealth AS ch
    GROUP BY ch.InstanceId
)
SELECT
    mi.InstanceId,
    mi.InstanceName,
    mi.EnvironmentName,
    mi.CollectionProfile,
    mi.ComplianceProfile,
    mi.SqlVersion,
    mi.Edition,
    bc.CaptureTime AS BackupCaptureTime,
    bc.DatabaseCount,
    bc.BackupProtectionIssueCount,
    bc.ConfigurationViolationCount,
    bc.NonCompliantDatabaseCount,
    bc.BackupHealth,
    bc.ConfigurationHealth,
    cs.LastCollectionTime,
    ISNULL(cs.CollectorCriticalCount,0) AS CollectorCriticalCount,
    ISNULL(cs.CollectorWarningCount,0) AS CollectorWarningCount,
    OverallHealth =
        CASE
            WHEN ISNULL(cs.CollectorCriticalCount,0) > 0 THEN N'Critical'
            WHEN bc.BackupHealth = N'Critical' THEN N'Critical'
            WHEN ISNULL(cs.CollectorWarningCount,0) > 0 THEN N'Warning'
            WHEN bc.ConfigurationHealth = N'Warning' THEN N'Warning'
            WHEN bc.BackupHealth = N'Unknown'
              OR bc.ConfigurationHealth = N'Unknown'
                THEN N'Warning'
            ELSE N'Healthy'
        END
FROM dbo.MonitoredInstances AS mi
LEFT JOIN rpt.vw_BackupComplianceCurrent AS bc
    ON bc.InstanceId = mi.InstanceId
LEFT JOIN CollectorSummary AS cs
    ON cs.InstanceId = mi.InstanceId
WHERE mi.IsEnabled = 1;
GO

/*=============================================================================
  14. Server Health Scorecard
=============================================================================*/
CREATE OR ALTER VIEW rpt.vw_ServerHealthScorecard
AS
WITH CollectorSummary AS
(
    SELECT
        InstanceId,
        CollectorCriticalCount =
            SUM(CASE WHEN CollectorHealth = N'Critical' THEN 1 ELSE 0 END),
        CollectorWarningCount =
            SUM(CASE WHEN CollectorHealth = N'Warning' THEN 1 ELSE 0 END),
        CollectorUnknownCount =
            SUM(CASE WHEN CollectorHealth = N'Unknown' THEN 1 ELSE 0 END),
        LastCollectionTime = MAX(LastStartedAt)
    FROM rpt.vw_CollectorHealth
    GROUP BY InstanceId
),
Base AS
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

        ISNULL(cs.CollectorCriticalCount, 0) AS CollectorCriticalCount,
        ISNULL(cs.CollectorWarningCount, 0) AS CollectorWarningCount,
        ISNULL(cs.CollectorUnknownCount, 0) AS CollectorUnknownCount,
        cs.LastCollectionTime

    FROM dbo.MonitoredInstances AS mi
    LEFT JOIN rpt.vw_PerformanceHealthCurrent AS ph
        ON ph.InstanceId = mi.InstanceId
    LEFT JOIN rpt.vw_BlockingHealthCurrent AS bh
        ON bh.InstanceId = mi.InstanceId
    LEFT JOIN rpt.vw_BackupComplianceCurrent AS bc
        ON bc.InstanceId = mi.InstanceId
    LEFT JOIN rpt.vw_QueryPressureCurrent AS q
        ON q.InstanceId = mi.InstanceId
    LEFT JOIN rpt.vw_DataFreshnessCurrent AS df
        ON df.InstanceId = mi.InstanceId
    LEFT JOIN CollectorSummary AS cs
        ON cs.InstanceId = mi.InstanceId
    WHERE mi.IsEnabled = 1
),
Scores AS
(
    SELECT
        b.*,
        OperationalPenalty =
              CASE b.CpuHealth
                  WHEN N'Critical' THEN 20
                  WHEN N'Warning'  THEN 10
                  WHEN N'Unknown'  THEN 5
                  ELSE 0
              END
            + CASE b.MemoryHealth
                  WHEN N'Critical' THEN 20
                  WHEN N'Warning'  THEN 10
                  WHEN N'Unknown'  THEN 5
                  ELSE 0
              END
            + CASE b.BlockingHealth
                  WHEN N'Critical' THEN 20
                  WHEN N'Warning'  THEN 10
                  WHEN N'Unknown'  THEN 5
                  ELSE 0
              END
            + CASE b.DeadlockHealth
                  WHEN N'Critical' THEN 15
                  WHEN N'Warning'  THEN 8
                  ELSE 0
              END
            + CASE b.FreshnessHealth
                  WHEN N'Critical' THEN 25
                  WHEN N'Warning'  THEN 15
                  WHEN N'Unknown'  THEN 10
                  ELSE 0
              END
            + CASE
                  WHEN b.CollectorCriticalCount > 0 THEN 25
                  WHEN b.CollectorWarningCount > 0 THEN 10
                  ELSE 0
              END,

        OverallPenalty =
              CASE b.CpuHealth
                  WHEN N'Critical' THEN 20
                  WHEN N'Warning'  THEN 10
                  WHEN N'Unknown'  THEN 5
                  ELSE 0
              END
            + CASE b.MemoryHealth
                  WHEN N'Critical' THEN 20
                  WHEN N'Warning'  THEN 10
                  WHEN N'Unknown'  THEN 5
                  ELSE 0
              END
            + CASE b.BlockingHealth
                  WHEN N'Critical' THEN 20
                  WHEN N'Warning'  THEN 10
                  WHEN N'Unknown'  THEN 5
                  ELSE 0
              END
            + CASE b.DeadlockHealth
                  WHEN N'Critical' THEN 15
                  WHEN N'Warning'  THEN 8
                  ELSE 0
              END
            + CASE b.BackupHealth
                  WHEN N'Critical' THEN 25
                  WHEN N'Warning'  THEN 10
                  WHEN N'Unknown'  THEN 5
                  ELSE 0
              END
            + CASE b.ConfigurationHealth
                  WHEN N'Critical' THEN 10
                  WHEN N'Warning'  THEN 5
                  WHEN N'Unknown'  THEN 3
                  ELSE 0
              END
            + CASE b.FreshnessHealth
                  WHEN N'Critical' THEN 25
                  WHEN N'Warning'  THEN 15
                  WHEN N'Unknown'  THEN 10
                  ELSE 0
              END
            + CASE
                  WHEN b.CollectorCriticalCount > 0 THEN 25
                  WHEN b.CollectorWarningCount > 0 THEN 10
                  ELSE 0
              END
    FROM Base AS b
)
SELECT
    s.InstanceId,
    s.InstanceName,
    s.EnvironmentName,
    s.CollectionProfile,
    s.ComplianceProfile,
    s.SqlVersion,
    s.Edition,

    s.PerformanceCaptureTime,
    s.SqlProcessCpuPercent,
    s.SystemCpuPercent,
    s.MemoryGrantsPending,
    s.PageLifeExpectancySeconds,
    s.DeadlocksSincePreviousSample,
    s.CpuHealth,
    s.MemoryHealth,
    s.DeadlockHealth,

    s.BlockingCaptureTime,
    s.BlockedSessionCount,
    s.DistinctBlockingSessionCount,
    s.MaxWaitSeconds,
    s.BlockingHealth,

    s.BackupCaptureTime,
    s.DatabaseCount,
    s.BackupProtectionIssueCount,
    s.ConfigurationViolationCount,
    s.BackupHealth,
    s.ConfigurationHealth,

    s.QueryStatsCaptureTime,
    s.DistinctQueriesCaptured,
    s.QueryDataHealth,

    s.LastCollectionAttempt,
    s.LatestCollectorSuccess,
    s.CollectorsNeverSuccessful,
    s.FreshnessHealth,

    s.CollectorCriticalCount,
    s.CollectorWarningCount,
    s.CollectorUnknownCount,
    s.LastCollectionTime,

    HealthScore =
        CONVERT
        (
            int,
            CASE
                WHEN 100 - s.OverallPenalty < 0 THEN 0
                ELSE 100 - s.OverallPenalty
            END
        ),

    OverallHealth =
        CASE
            WHEN s.CollectorCriticalCount > 0 THEN N'Critical'
            WHEN s.FreshnessHealth = N'Critical' THEN N'Critical'
            WHEN s.CpuHealth = N'Critical' THEN N'Critical'
            WHEN s.MemoryHealth = N'Critical' THEN N'Critical'
            WHEN s.BlockingHealth = N'Critical' THEN N'Critical'
            WHEN s.DeadlockHealth = N'Critical' THEN N'Critical'
            WHEN s.BackupHealth = N'Critical' THEN N'Critical'

            WHEN s.CollectorWarningCount > 0 THEN N'Warning'
            WHEN s.FreshnessHealth IN (N'Warning', N'Unknown') THEN N'Warning'
            WHEN s.CpuHealth IN (N'Warning', N'Unknown') THEN N'Warning'
            WHEN s.MemoryHealth IN (N'Warning', N'Unknown') THEN N'Warning'
            WHEN s.BlockingHealth IN (N'Warning', N'Unknown') THEN N'Warning'
            WHEN s.DeadlockHealth = N'Warning' THEN N'Warning'
            WHEN s.BackupHealth IN (N'Warning', N'Unknown') THEN N'Warning'
            WHEN s.ConfigurationHealth IN (N'Warning', N'Unknown') THEN N'Warning'
            ELSE N'Healthy'
        END,

    OperationalHealthScore =
        CONVERT
        (
            int,
            CASE
                WHEN 100 - s.OperationalPenalty < 0 THEN 0
                ELSE 100 - s.OperationalPenalty
            END
        ),

    OperationalHealth =
        CASE
            WHEN s.CollectorCriticalCount > 0 THEN N'Critical'
            WHEN s.FreshnessHealth = N'Critical' THEN N'Critical'
            WHEN s.CpuHealth = N'Critical' THEN N'Critical'
            WHEN s.MemoryHealth = N'Critical' THEN N'Critical'
            WHEN s.BlockingHealth = N'Critical' THEN N'Critical'
            WHEN s.DeadlockHealth = N'Critical' THEN N'Critical'

            WHEN s.CollectorWarningCount > 0 THEN N'Warning'
            WHEN s.FreshnessHealth IN (N'Warning', N'Unknown') THEN N'Warning'
            WHEN s.CpuHealth IN (N'Warning', N'Unknown') THEN N'Warning'
            WHEN s.MemoryHealth IN (N'Warning', N'Unknown') THEN N'Warning'
            WHEN s.BlockingHealth IN (N'Warning', N'Unknown') THEN N'Warning'
            WHEN s.DeadlockHealth = N'Warning' THEN N'Warning'
            ELSE N'Healthy'
        END,

    ComplianceHealth =
        CASE
            WHEN s.BackupHealth = N'Critical'
              OR s.ConfigurationHealth = N'Critical'
                THEN N'Critical'
            WHEN s.BackupHealth IN (N'Warning', N'Unknown')
              OR s.ConfigurationHealth IN (N'Warning', N'Unknown')
                THEN N'Warning'
            ELSE N'Healthy'
        END

FROM Scores AS s;
GO

/*=============================================================================
  15. Active Operational Issues
=============================================================================*/
CREATE OR ALTER VIEW rpt.vw_ActiveOperationalIssues
AS
SELECT
    s.InstanceId,
    s.InstanceName,
    s.EnvironmentName,
    IssueCategory = N'CPU',
    Severity = s.CpuHealth,
    Issue = N'SQL Server CPU health is ' + s.CpuHealth,
    DetectedAt = s.PerformanceCaptureTime,
    MetricValue = CONVERT(decimal(19,2), s.SqlProcessCpuPercent),
    MetricUnit = N'Percent',
    Details = CONCAT
    (
        N'SQL CPU: ',
        CONVERT(varchar(30),s.SqlProcessCpuPercent),
        N'%, System CPU: ',
        CONVERT(varchar(30),s.SystemCpuPercent),
        N'%'
    )
FROM rpt.vw_ServerHealthScorecard AS s
WHERE s.CpuHealth IN(N'Warning',N'Critical')

UNION ALL

SELECT
    s.InstanceId,
    s.InstanceName,
    s.EnvironmentName,
    N'Memory',
    s.MemoryHealth,
    N'SQL Server memory health is ' + s.MemoryHealth,
    s.PerformanceCaptureTime,
    CONVERT(decimal(19,2),s.MemoryGrantsPending),
    N'Pending Grants',
    CONCAT
    (
        N'Memory Grants Pending: ',
        CONVERT(varchar(30),s.MemoryGrantsPending),
        N', PLE: ',
        CONVERT(varchar(30),s.PageLifeExpectancySeconds),
        N' sec'
    )
FROM rpt.vw_ServerHealthScorecard AS s
WHERE s.MemoryHealth IN(N'Warning',N'Critical')

UNION ALL

SELECT
    s.InstanceId,
    s.InstanceName,
    s.EnvironmentName,
    N'Blocking',
    s.BlockingHealth,
    CONCAT
    (
        N'Blocking detected - ',
        CONVERT(varchar(30),s.BlockedSessionCount),
        N' blocked session(s)'
    ),
    s.BlockingCaptureTime,
    CONVERT(decimal(19,2),s.MaxWaitSeconds),
    N'Seconds',
    CONCAT
    (
        N'Blocked sessions: ',
        CONVERT(varchar(30),s.BlockedSessionCount),
        N', Distinct blockers: ',
        CONVERT(varchar(30),s.DistinctBlockingSessionCount),
        N', Max wait: ',
        CONVERT(varchar(30),s.MaxWaitSeconds),
        N' sec'
    )
FROM rpt.vw_ServerHealthScorecard AS s
WHERE s.BlockingHealth IN(N'Warning',N'Critical')

UNION ALL

SELECT
    s.InstanceId,
    s.InstanceName,
    s.EnvironmentName,
    N'Deadlock',
    s.DeadlockHealth,
    CONCAT
    (
        N'Deadlocks detected - ',
        CONVERT(varchar(30),s.DeadlocksSincePreviousSample)
    ),
    s.PerformanceCaptureTime,
    CONVERT(decimal(19,2),s.DeadlocksSincePreviousSample),
    N'Deadlocks',
    CONCAT
    (
        N'Deadlocks since previous sample: ',
        CONVERT(varchar(30),s.DeadlocksSincePreviousSample)
    )
FROM rpt.vw_ServerHealthScorecard AS s
WHERE s.DeadlockHealth IN(N'Warning',N'Critical')

UNION ALL

SELECT
    s.InstanceId,
    s.InstanceName,
    s.EnvironmentName,
    N'Data Freshness',
    s.FreshnessHealth,
    N'Monitoring data freshness is ' + s.FreshnessHealth,
    s.LastCollectionAttempt,
    CONVERT(decimal(19,2),s.CollectorsNeverSuccessful),
    N'Collectors',
    CONCAT
    (
        N'Collectors never successful: ',
        CONVERT(varchar(30),s.CollectorsNeverSuccessful),
        N', Latest collector success: ',
        CONVERT(varchar(30),s.LatestCollectorSuccess,120)
    )
FROM rpt.vw_ServerHealthScorecard AS s
WHERE s.FreshnessHealth IN(N'Warning',N'Critical')

UNION ALL

SELECT
    c.InstanceId,
    c.InstanceName,
    c.EnvironmentName,
    N'Collector',
    c.CollectorHealth,
    CONCAT(N'Collector ',c.CollectorName,N' is ',c.CollectorHealth),
    c.LastStartedAt,
    CONVERT(decimal(19,2),c.DurationMs),
    N'Milliseconds',
    CONCAT
    (
        N'Collector: ',
        c.CollectorName,
        N'; Last status: ',
        ISNULL(c.LastStatus,N'Unknown'),
        N'; Error: ',
        ISNULL(c.ErrorMessage,N'')
    )
FROM rpt.vw_CollectorHealth AS c
WHERE c.CollectorHealth IN(N'Warning',N'Critical')

UNION ALL

SELECT
    a.InstanceId,
    a.InstanceName,
    a.EnvironmentName,
    N'SQL Agent',
    N'Critical',
    CONCAT
    (
        CONVERT(varchar(30),a.RecentFailedJobs),
        N' recent failed SQL Agent job(s)'
    ),
    a.CaptureTime,
    CONVERT(decimal(19,2),a.RecentFailedJobs),
    N'Jobs',
    CONCAT
    (
        N'Failed: ',
        CONVERT(varchar(30),a.RecentFailedJobs),
        N', Canceled: ',
        CONVERT(varchar(30),a.RecentCanceledJobs),
        N', Retry: ',
        CONVERT(varchar(30),a.RecentRetryJobs)
    )
FROM rpt.vw_SQLAgentHealthCurrent AS a
WHERE ISNULL(a.RecentFailedJobs,0)>0

UNION ALL

SELECT
    a.InstanceId,
    a.InstanceName,
    a.EnvironmentName,
    N'SQL Agent',
    N'Warning',
    CONCAT
    (
        CONVERT(varchar(30),a.RecentCanceledJobs),
        N' recent canceled SQL Agent job(s)'
    ),
    a.CaptureTime,
    CONVERT(decimal(19,2),a.RecentCanceledJobs),
    N'Jobs',
    CONCAT
    (
        N'Canceled: ',
        CONVERT(varchar(30),a.RecentCanceledJobs)
    )
FROM rpt.vw_SQLAgentHealthCurrent AS a
WHERE ISNULL(a.RecentCanceledJobs,0)>0

UNION ALL

SELECT
    a.InstanceId,
    a.InstanceName,
    a.EnvironmentName,
    N'SQL Agent',
    N'Warning',
    CONCAT
    (
        CONVERT(varchar(30),a.RecentRetryJobs),
        N' SQL Agent job retry event(s)'
    ),
    a.CaptureTime,
    CONVERT(decimal(19,2),a.RecentRetryJobs),
    N'Jobs',
    CONCAT
    (
        N'Retry events: ',
        CONVERT(varchar(30),a.RecentRetryJobs)
    )
FROM rpt.vw_SQLAgentHealthCurrent AS a
WHERE ISNULL(a.RecentRetryJobs,0)>0;
GO
