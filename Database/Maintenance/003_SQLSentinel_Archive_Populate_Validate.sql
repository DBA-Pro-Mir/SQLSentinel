/*
 SQLSentinel history population + validation (SQL Server 2017)
 No raw deletes. Run after 002_Create_SQLSentinel_Monthly_History.sql.
 Daily rollups are atomically replaced for an elapsed day.
 NOTE: Archive granularities deliberately differ by source:
  MetricSnapshot: instance/collector/category/counter daily statistics.
  MetricTextSnapshot: instance/category/detail/severity counts only.
  CollectionRunHistory: instance/collector/status counts only.
  Capacity: daily instance totals across databases, or volume-free metrics.
  This is NOT a per-database historical archive.
*/
USE [SQLMonitoring];
GO

CREATE OR ALTER PROCEDURE [dbo].[usp_SQLSentinelArchiveDaily]
    @RollupDate date,
    @DryRun bit = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @RollupDate IS NULL OR @RollupDate >= CONVERT(date,SYSDATETIME())
        THROW 50120, 'RollupDate must be a completed calendar day.', 1;

    DECLARE @From datetime2(0)=CONVERT(datetime2(0),@RollupDate);
    DECLARE @To datetime2(0)=DATEADD(DAY,1,@From);

    CREATE TABLE #Counts ([SourceTable] varchar(40) NOT NULL PRIMARY KEY,[RowCount] bigint NOT NULL);
    INSERT INTO #Counts ([SourceTable],[RowCount])
    SELECT 'MetricSnapshot',COUNT_BIG(*) FROM dbo.MetricSnapshot WHERE CaptureTime>=@From AND CaptureTime<@To
    UNION ALL SELECT 'MetricTextSnapshot',COUNT_BIG(*) FROM dbo.MetricTextSnapshot WHERE CaptureTime>=@From AND CaptureTime<@To
    UNION ALL SELECT 'CollectionRunHistory',COUNT_BIG(*) FROM dbo.CollectionRunHistory WHERE StartedAt>=@From AND StartedAt<@To
    UNION ALL SELECT 'DatabaseCapacitySnapshot',COUNT_BIG(*) FROM dbo.DatabaseCapacitySnapshot WHERE CaptureTime>=@From AND CaptureTime<@To
    UNION ALL SELECT 'VolumeCapacitySnapshot',COUNT_BIG(*) FROM dbo.VolumeCapacitySnapshot WHERE CaptureTime>=@From AND CaptureTime<@To;

    IF @DryRun=1
    BEGIN
        SELECT @RollupDate AS [RollupDate],[SourceTable],[RowCount] AS [SourceRows] FROM #Counts ORDER BY [SourceTable];
        RETURN;
    END;

    DECLARE @LockResult int;
    EXEC @LockResult=sys.sp_getapplock
        @Resource=N'SQLSentinelArchiveDaily',@LockMode='Exclusive',
        @LockOwner='Session',@LockTimeout=0;
    IF @LockResult<0 THROW 50121,'Another archive session is running.',1;

    BEGIN TRY
        BEGIN TRANSACTION;
        /* Recompute source counts under the same transaction used to store the
           audit. Existing raw rows must not be concurrently deleted by cleanup. */
        DELETE FROM #Counts;
        INSERT INTO #Counts ([SourceTable],[RowCount])
        SELECT 'MetricSnapshot',COUNT_BIG(*) FROM dbo.MetricSnapshot WHERE CaptureTime>=@From AND CaptureTime<@To
        UNION ALL SELECT 'MetricTextSnapshot',COUNT_BIG(*) FROM dbo.MetricTextSnapshot WHERE CaptureTime>=@From AND CaptureTime<@To
        UNION ALL SELECT 'CollectionRunHistory',COUNT_BIG(*) FROM dbo.CollectionRunHistory WHERE StartedAt>=@From AND StartedAt<@To
        UNION ALL SELECT 'DatabaseCapacitySnapshot',COUNT_BIG(*) FROM dbo.DatabaseCapacitySnapshot WHERE CaptureTime>=@From AND CaptureTime<@To
        UNION ALL SELECT 'VolumeCapacitySnapshot',COUNT_BIG(*) FROM dbo.VolumeCapacitySnapshot WHERE CaptureTime>=@From AND CaptureTime<@To;

        DELETE FROM dbo.SQLSentinelDailyRollup WHERE RollupDate=@RollupDate;
        DELETE FROM dbo.SQLSentinelRollupAudit WHERE RollupDate=@RollupDate;

        INSERT dbo.SQLSentinelDailyRollup
        ([RollupDate],[InstanceId],[SourceTable],[SourceCollector],[MetricCategory],[MetricName],
         [SampleCount],[ValueSum],[ValueMin],[ValueMax],[LastCaptureTime])
        SELECT @RollupDate,InstanceId,'MetricSnapshot',SourceCollector,
               CONVERT(nvarchar(100),MetricCategory),CONVERT(nvarchar(200),CounterName),
               COUNT_BIG(*),SUM(CONVERT(decimal(38,6),MetricValue)),
               MIN(MetricValue),MAX(MetricValue),MAX(CaptureTime)
        FROM dbo.MetricSnapshot
        WHERE CaptureTime>=@From AND CaptureTime<@To
        GROUP BY InstanceId,SourceCollector,MetricCategory,CounterName;

        /* No event SQL text, XML, or sensitive payload is copied. */
        INSERT dbo.SQLSentinelDailyRollup
        ([RollupDate],[InstanceId],[SourceTable],[SourceCollector],[MetricCategory],[MetricName],
         [SampleCount],[ValueSum],[ValueMin],[ValueMax],[LastCaptureTime])
        SELECT @RollupDate,InstanceId,'MetricTextSnapshot',SourceCollector,
               CONVERT(nvarchar(100),MetricCategory),
               CONVERT(nvarchar(200),CONCAT(DetailType,N' / ',COALESCE(Severity,N'Unknown'))),
               COUNT_BIG(*),CONVERT(decimal(38,6),COUNT_BIG(*)),
               NULL,NULL,MAX(CaptureTime)
        FROM dbo.MetricTextSnapshot
        WHERE CaptureTime>=@From AND CaptureTime<@To
        GROUP BY InstanceId,SourceCollector,MetricCategory,DetailType,Severity;

        INSERT dbo.SQLSentinelDailyRollup
        ([RollupDate],[InstanceId],[SourceTable],[SourceCollector],[MetricCategory],[MetricName],
         [SampleCount],[ValueSum],[ValueMin],[ValueMax],[LastCaptureTime])
        SELECT @RollupDate,InstanceId,'CollectionRunHistory',CollectorName,
               N'CollectorRun',CONVERT(nvarchar(200),Status),
               COUNT_BIG(*),CONVERT(decimal(38,6),COUNT_BIG(*)),
               NULL,NULL,MAX(StartedAt)
        FROM dbo.CollectionRunHistory
        WHERE StartedAt>=@From AND StartedAt<@To
        GROUP BY InstanceId,CollectorName,Status;

        /* Sum database sizes per observed server timestamp first, then
           summarize server capacity across timestamps. */
        ;WITH [CapacityPerCapture] AS
        (
            SELECT InstanceId,CaptureTime,
                   SUM(CONVERT(decimal(28,6),TotalSizeGB)) AS [TotalSizeGB],
                   SUM(CONVERT(decimal(28,6),DataSizeGB)) AS [DataSizeGB],
                   SUM(CONVERT(decimal(28,6),LogSizeGB)) AS [LogSizeGB]
            FROM dbo.DatabaseCapacitySnapshot
            WHERE CaptureTime>=@From AND CaptureTime<@To
            GROUP BY InstanceId,CaptureTime
        ),[Unpivoted] AS
        (
            SELECT [c].[InstanceId],[c].[CaptureTime],[v].[MetricName],[v].[MetricValue]
            FROM [CapacityPerCapture] AS [c]
            CROSS APPLY (VALUES
                (N'TotalDatabaseSizeGB',[c].[TotalSizeGB]),
                (N'DataSizeGB',[c].[DataSizeGB]),
                (N'LogSizeGB',[c].[LogSizeGB])
            ) AS [v]([MetricName],[MetricValue])
        )
        INSERT dbo.SQLSentinelDailyRollup
        ([RollupDate],[InstanceId],[SourceTable],[SourceCollector],[MetricCategory],[MetricName],
         [SampleCount],[ValueSum],[ValueMin],[ValueMax],[LastCaptureTime])
        SELECT @RollupDate,InstanceId,'DatabaseCapacitySnapshot',N'Collect-Storage',
               N'Capacity',MetricName,COUNT_BIG(*),SUM(CONVERT(decimal(38,6),MetricValue)),
               MIN(MetricValue),MAX(MetricValue),MAX(CaptureTime)
        FROM [Unpivoted]
        GROUP BY InstanceId,MetricName;

        INSERT dbo.SQLSentinelDailyRollup
        ([RollupDate],[InstanceId],[SourceTable],[SourceCollector],[MetricCategory],[MetricName],
         [SampleCount],[ValueSum],[ValueMin],[ValueMax],[LastCaptureTime])
        SELECT @RollupDate,InstanceId,'VolumeCapacitySnapshot',N'Collect-Storage',
               N'Capacity',N'VolumeFreePercent',COUNT_BIG(*),
               SUM(CONVERT(decimal(38,6),FreePercent)),
               MIN(CONVERT(decimal(28,6),FreePercent)),MAX(CONVERT(decimal(28,6),FreePercent)),
               MAX(CaptureTime)
        FROM dbo.VolumeCapacitySnapshot
        WHERE CaptureTime>=@From AND CaptureTime<@To
        GROUP BY InstanceId;

        INSERT dbo.SQLSentinelRollupAudit
        ([RollupDate],[SourceTable],[SourceRows],[SummaryRows],[CompletedAt])
        SELECT @RollupDate,[c].[SourceTable],[c].[RowCount],
               (SELECT COUNT_BIG(*) FROM dbo.SQLSentinelDailyRollup AS [r]
                 WHERE [r].[RollupDate]=@RollupDate AND [r].[SourceTable]=[c].[SourceTable]),
               SYSDATETIME()
        FROM #Counts AS [c];

        /* A nonempty source must always produce some archive rows. */
        IF EXISTS
        (
            SELECT 1 FROM dbo.SQLSentinelRollupAudit
            WHERE RollupDate=@RollupDate AND SourceRows>0 AND SummaryRows=0
        )
            THROW 50122,'Archive produced no rollups for nonempty source.',1;

        COMMIT TRANSACTION;
        EXEC sys.sp_releaseapplock @Resource=N'SQLSentinelArchiveDaily',@LockOwner='Session';

        SELECT [RollupDate],[SourceTable],[SourceRows],[SummaryRows],[CompletedAt]
        FROM dbo.SQLSentinelRollupAudit WHERE RollupDate=@RollupDate
        ORDER BY SourceTable;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT>0 ROLLBACK TRANSACTION;
        EXEC sys.sp_releaseapplock @Resource=N'SQLSentinelArchiveDaily',@LockOwner='Session';
        THROW;
    END CATCH;
END;
GO

/* Read-only coverage verifier. Throws when a source day has current rows but
   its audit is missing or stale, including late-arriving records. */
CREATE OR ALTER PROCEDURE [dbo].[usp_SQLSentinelValidateArchiveCoverage]
    @FromDate date,
    @ThroughDate date
AS
BEGIN
    SET NOCOUNT ON;
    IF @FromDate IS NULL OR @ThroughDate IS NULL OR @FromDate>@ThroughDate
        THROW 50130,'Invalid coverage date range.',1;
    DECLARE @End date=DATEADD(DAY,1,@ThroughDate);

    ;WITH [SourceCounts] AS
    (
        SELECT CONVERT(date,CaptureTime) AS [RollupDate],
               CONVERT(varchar(40),'MetricSnapshot') AS [SourceTable],COUNT_BIG(*) AS [SourceRows]
        FROM dbo.MetricSnapshot WHERE CaptureTime>=@FromDate AND CaptureTime<@End
        GROUP BY CONVERT(date,CaptureTime)
        UNION ALL
        SELECT CONVERT(date,CaptureTime),'MetricTextSnapshot',COUNT_BIG(*)
        FROM dbo.MetricTextSnapshot WHERE CaptureTime>=@FromDate AND CaptureTime<@End
        GROUP BY CONVERT(date,CaptureTime)
        UNION ALL
        SELECT CONVERT(date,StartedAt),'CollectionRunHistory',COUNT_BIG(*)
        FROM dbo.CollectionRunHistory WHERE StartedAt>=@FromDate AND StartedAt<@End
        GROUP BY CONVERT(date,StartedAt)
        UNION ALL
        SELECT CONVERT(date,CaptureTime),'DatabaseCapacitySnapshot',COUNT_BIG(*)
        FROM dbo.DatabaseCapacitySnapshot WHERE CaptureTime>=@FromDate AND CaptureTime<@End
        GROUP BY CONVERT(date,CaptureTime)
        UNION ALL
        SELECT CONVERT(date,CaptureTime),'VolumeCapacitySnapshot',COUNT_BIG(*)
        FROM dbo.VolumeCapacitySnapshot WHERE CaptureTime>=@FromDate AND CaptureTime<@End
        GROUP BY CONVERT(date,CaptureTime)
    )
    SELECT [s].[RollupDate],[s].[SourceTable],[s].[SourceRows],
           [a].[SourceRows] AS [ArchivedSourceRows],[a].[SummaryRows],
           [a].[CompletedAt],
           CASE WHEN [a].[RollupDate] IS NULL THEN N'MISSING'
                WHEN [a].[SourceRows]<>[s].[SourceRows] THEN N'STALE'
                WHEN [s].[SourceRows]>0 AND [a].[SummaryRows]=0 THEN N'EMPTY'
                ELSE N'OK' END AS [CoverageStatus]
    FROM [SourceCounts] AS [s]
    LEFT JOIN dbo.SQLSentinelRollupAudit AS [a]
      ON [a].[RollupDate]=[s].[RollupDate] AND [a].[SourceTable]=[s].[SourceTable]
    ORDER BY [s].[RollupDate],[s].[SourceTable];
END;
GO

/* Explicit date-range backfill. Runs only with @DryRun=0 and is limited to
   completed days. Errors stop immediately; previously archived days persist. */
CREATE OR ALTER PROCEDURE [dbo].[usp_SQLSentinelArchiveBackfill]
    @FromDate date,
    @ThroughDate date,
    @DryRun bit = 1
AS
BEGIN
    SET NOCOUNT ON;
    IF @FromDate IS NULL OR @ThroughDate IS NULL OR @FromDate>@ThroughDate
      OR @ThroughDate>=CONVERT(date,SYSDATETIME())
        THROW 50140,'Backfill requires completed calendar dates.',1;
    IF DATEDIFF(DAY,@FromDate,@ThroughDate)>400
        THROW 50141,'Backfill range exceeds 401 days.',1;
    DECLARE @Day date=@FromDate;
    WHILE @Day<=@ThroughDate
    BEGIN
        EXEC dbo.usp_SQLSentinelArchiveDaily @RollupDate=@Day,@DryRun=@DryRun;
        SET @Day=DATEADD(DAY,1,@Day);
    END;
END;
GO
