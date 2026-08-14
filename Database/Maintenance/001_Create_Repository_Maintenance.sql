/*
===============================================================================
 SQLSentinel - Repository Retention and Maintenance
===============================================================================
 Run in SQLMonitoring.

 Initial retention policy:
   MetricSnapshot          90 days
   MetricTextSnapshot      90 days
   CollectionRunHistory   365 days

 Deletes are intentionally batched to limit transaction log growth, blocking,
 and long-running cleanup transactions. Retention can be tightened later when
 collector frequency increases.
===============================================================================
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_SQLSentinel_RepositoryCleanup
    @MetricRetentionDays int = 90,
    @TextRetentionDays int = 90,
    @CollectionHistoryRetentionDays int = 365,
    @BatchSize int = 5000,
    @DelayMilliseconds int = 100,
    @MaxBatchesPerTable int = 1000
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @MetricRetentionDays < 7 OR @TextRetentionDays < 7 OR @CollectionHistoryRetentionDays < 30
        THROW 50020, 'Retention values are below SQLSentinel safety minimums.', 1;

    IF @BatchSize < 100 OR @BatchSize > 50000
        THROW 50021, 'BatchSize must be between 100 and 50000.', 1;

    IF @MaxBatchesPerTable < 1
        THROW 50022, 'MaxBatchesPerTable must be at least 1.', 1;

    DECLARE @MetricCutoff datetime2 = DATEADD(DAY, -@MetricRetentionDays, SYSDATETIME());
    DECLARE @TextCutoff datetime2 = DATEADD(DAY, -@TextRetentionDays, SYSDATETIME());
    DECLARE @HistoryCutoff datetime2 = DATEADD(DAY, -@CollectionHistoryRetentionDays, SYSDATETIME());
    DECLARE @Rows int;
    DECLARE @Batch int;
    DECLARE @Delay time(3) = DATEADD(MILLISECOND, @DelayMilliseconds, CAST('00:00:00.000' AS time(3)));

    CREATE TABLE #CleanupSummary
    (
        TableName sysname NOT NULL,
        RowsDeleted bigint NOT NULL,
        CutoffDate datetime2 NOT NULL
    );

    DECLARE @Total bigint = 0;
    SET @Batch = 0;
    WHILE @Batch < @MaxBatchesPerTable
    BEGIN
        DELETE TOP (@BatchSize)
        FROM dbo.MetricSnapshot
        WHERE CaptureTime < @MetricCutoff;

        SET @Rows = @@ROWCOUNT;
        SET @Total += @Rows;
        SET @Batch += 1;
        IF @Rows = 0 BREAK;
        IF @DelayMilliseconds > 0 WAITFOR DELAY @Delay;
    END;
    INSERT #CleanupSummary VALUES (N'MetricSnapshot', @Total, @MetricCutoff);

    SET @Total = 0;
    SET @Batch = 0;
    WHILE @Batch < @MaxBatchesPerTable
    BEGIN
        DELETE TOP (@BatchSize)
        FROM dbo.MetricTextSnapshot
        WHERE CaptureTime < @TextCutoff;

        SET @Rows = @@ROWCOUNT;
        SET @Total += @Rows;
        SET @Batch += 1;
        IF @Rows = 0 BREAK;
        IF @DelayMilliseconds > 0 WAITFOR DELAY @Delay;
    END;
    INSERT #CleanupSummary VALUES (N'MetricTextSnapshot', @Total, @TextCutoff);

    SET @Total = 0;
    SET @Batch = 0;
    WHILE @Batch < @MaxBatchesPerTable
    BEGIN
        DELETE TOP (@BatchSize)
        FROM dbo.CollectionRunHistory
        WHERE StartedAt < @HistoryCutoff;

        SET @Rows = @@ROWCOUNT;
        SET @Total += @Rows;
        SET @Batch += 1;
        IF @Rows = 0 BREAK;
        IF @DelayMilliseconds > 0 WAITFOR DELAY @Delay;
    END;
    INSERT #CleanupSummary VALUES (N'CollectionRunHistory', @Total, @HistoryCutoff);

    SELECT TableName, RowsDeleted, CutoffDate
    FROM #CleanupSummary
    ORDER BY TableName;
END;
GO

CREATE OR ALTER VIEW rpt.vw_RepositoryHealth
AS
SELECT
    DatabaseName = DB_NAME(),
    DataSizeMB = CAST(SUM(CASE WHEN df.type = 0 THEN df.size ELSE 0 END) * 8.0 / 1024.0 AS decimal(19,2)),
    LogSizeMB = CAST(SUM(CASE WHEN df.type = 1 THEN df.size ELSE 0 END) * 8.0 / 1024.0 AS decimal(19,2)),
    TotalAllocatedMB = CAST(SUM(df.size) * 8.0 / 1024.0 AS decimal(19,2)),
    DataFileCount = SUM(CASE WHEN df.type = 0 THEN 1 ELSE 0 END),
    LogFileCount = SUM(CASE WHEN df.type = 1 THEN 1 ELSE 0 END),
    CaptureTime = SYSDATETIME()
FROM sys.database_files AS df;
GO

PRINT 'SQLSentinel repository maintenance objects created/updated successfully.';
GO
