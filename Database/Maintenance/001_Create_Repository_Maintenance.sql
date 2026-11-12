/*
===============================================================================
 SQLSentinel - Repository Retention and Maintenance
===============================================================================
 Run in SQLMonitoring.

 Current retention policy:
   MetricSnapshot                 30 days
   MetricTextSnapshot             60 days
   Operational event text         30 days
   CollectionRunHistory           90 days
   DatabaseCapacitySnapshot       90 days
   VolumeCapacitySnapshot         90 days

 Deletes are intentionally batched to limit transaction log growth, blocking,
 and long-running cleanup transactions.

 Use @DryRun = 1 before changing retention values or before the first cleanup.
 Do not shrink SQLMonitoring after cleanup; freed space should be reused.
===============================================================================
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'rpt')
    EXEC(N'CREATE SCHEMA rpt AUTHORIZATION dbo;');
GO

IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dbo.MetricTextSnapshot')
      AND name = N'IX_MetricTextSnapshot_CaptureTime'
)
BEGIN
    CREATE NONCLUSTERED INDEX IX_MetricTextSnapshot_CaptureTime
        ON dbo.MetricTextSnapshot ([CaptureTime]);
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_SQLSentinelRepositoryCleanup
(
    @MetricRetentionDays             int = 30,
    @TextMetricRetentionDays         int = 60,
    @OperationalEventRetentionDays   int = 30,
    @CollectionRunRetentionDays      int = 90,
    @DatabaseCapacityRetentionDays   int = 90,
    @VolumeCapacityRetentionDays     int = 90,
    @BatchSize                       int = 10000,
    @DryRun                          bit = 1
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @MetricRetentionDays < 7
       OR @TextMetricRetentionDays < 7
       OR @OperationalEventRetentionDays < 7
       OR @CollectionRunRetentionDays < 30
       OR @DatabaseCapacityRetentionDays < 30
       OR @VolumeCapacityRetentionDays < 30
    BEGIN
        THROW 50020, 'Retention values are below SQLSentinel safety minimums.', 1;
    END;

    IF @BatchSize < 100 OR @BatchSize > 50000
        THROW 50021, 'BatchSize must be between 100 and 50000.', 1;

    DECLARE
        @MetricCutoff             datetime2(0) = DATEADD(DAY, -@MetricRetentionDays, SYSDATETIME()),
        @TextMetricCutoff         datetime2(0) = DATEADD(DAY, -@TextMetricRetentionDays, SYSDATETIME()),
        @OperationalEventCutoff   datetime2(0) = DATEADD(DAY, -@OperationalEventRetentionDays, SYSDATETIME()),
        @CollectionRunCutoff      datetime2(0) = DATEADD(DAY, -@CollectionRunRetentionDays, SYSDATETIME()),
        @DatabaseCapacityCutoff   datetime2(0) = DATEADD(DAY, -@DatabaseCapacityRetentionDays, SYSDATETIME()),
        @VolumeCapacityCutoff     datetime2(0) = DATEADD(DAY, -@VolumeCapacityRetentionDays, SYSDATETIME()),
        @RowsDeleted              int;

    IF @DryRun = 1
    BEGIN
        SELECT
            N'MetricSnapshot' AS [TableName],
            COUNT_BIG(*) AS [RowsToDelete],
            @MetricCutoff AS [CutoffDate]
        FROM dbo.MetricSnapshot
        WHERE [CaptureTime] < @MetricCutoff

        UNION ALL

        SELECT
            N'MetricTextSnapshot',
            COUNT_BIG(*),
            @TextMetricCutoff
        FROM dbo.MetricTextSnapshot
        WHERE [CaptureTime] < @TextMetricCutoff

        UNION ALL

        SELECT
            N'OperationalEvents',
            COUNT_BIG(*),
            @OperationalEventCutoff
        FROM dbo.MetricTextSnapshot
        WHERE [CaptureTime] < @OperationalEventCutoff
          AND [MetricCategory] IN (N'SqlAgentJob',N'SqlAgentAlert',N'SqlErrorLog')

        UNION ALL

        SELECT
            N'CollectionRunHistory',
            COUNT_BIG(*),
            @CollectionRunCutoff
        FROM dbo.CollectionRunHistory
        WHERE [StartedAt] < @CollectionRunCutoff

        UNION ALL

        SELECT
            N'DatabaseCapacitySnapshot',
            COUNT_BIG(*),
            @DatabaseCapacityCutoff
        FROM dbo.DatabaseCapacitySnapshot
        WHERE [CaptureTime] < @DatabaseCapacityCutoff

        UNION ALL

        SELECT
            N'VolumeCapacitySnapshot',
            COUNT_BIG(*),
            @VolumeCapacityCutoff
        FROM dbo.VolumeCapacitySnapshot
        WHERE [CaptureTime] < @VolumeCapacityCutoff;

        RETURN;
    END;

    SET @RowsDeleted = 1;
    WHILE @RowsDeleted > 0
    BEGIN
        DELETE TOP (@BatchSize)
        FROM dbo.MetricSnapshot
        WHERE [CaptureTime] < @MetricCutoff;

        SET @RowsDeleted = @@ROWCOUNT;
        IF @RowsDeleted > 0 WAITFOR DELAY '00:00:00.200';
    END;

    SET @RowsDeleted = 1;
    WHILE @RowsDeleted > 0
    BEGIN
        DELETE TOP (@BatchSize)
        FROM dbo.MetricTextSnapshot
        WHERE [CaptureTime] < @OperationalEventCutoff
          AND [MetricCategory] IN (N'SqlAgentJob',N'SqlAgentAlert',N'SqlErrorLog');

        SET @RowsDeleted = @@ROWCOUNT;
        IF @RowsDeleted > 0 WAITFOR DELAY '00:00:00.200';
    END;

    SET @RowsDeleted = 1;
    WHILE @RowsDeleted > 0
    BEGIN
        DELETE TOP (@BatchSize)
        FROM dbo.MetricTextSnapshot
        WHERE [CaptureTime] < @TextMetricCutoff;

        SET @RowsDeleted = @@ROWCOUNT;
        IF @RowsDeleted > 0 WAITFOR DELAY '00:00:00.200';
    END;

    SET @RowsDeleted = 1;
    WHILE @RowsDeleted > 0
    BEGIN
        DELETE TOP (@BatchSize)
        FROM dbo.CollectionRunHistory
        WHERE [StartedAt] < @CollectionRunCutoff;

        SET @RowsDeleted = @@ROWCOUNT;
        IF @RowsDeleted > 0 WAITFOR DELAY '00:00:00.200';
    END;

    SET @RowsDeleted = 1;
    WHILE @RowsDeleted > 0
    BEGIN
        DELETE TOP (@BatchSize)
        FROM dbo.DatabaseCapacitySnapshot
        WHERE [CaptureTime] < @DatabaseCapacityCutoff;

        SET @RowsDeleted = @@ROWCOUNT;
        IF @RowsDeleted > 0 WAITFOR DELAY '00:00:00.200';
    END;

    SET @RowsDeleted = 1;
    WHILE @RowsDeleted > 0
    BEGIN
        DELETE TOP (@BatchSize)
        FROM dbo.VolumeCapacitySnapshot
        WHERE [CaptureTime] < @VolumeCapacityCutoff;

        SET @RowsDeleted = @@ROWCOUNT;
        IF @RowsDeleted > 0 WAITFOR DELAY '00:00:00.200';
    END;
END;
GO

CREATE OR ALTER VIEW rpt.vw_RepositoryHealth
AS
SELECT
    [DatabaseName] = DB_NAME(),
    [DataSizeMB] = CAST(SUM(CASE WHEN df.[type] = 0 THEN df.[size] ELSE 0 END) * 8.0 / 1024.0 AS decimal(19,2)),
    [LogSizeMB] = CAST(SUM(CASE WHEN df.[type] = 1 THEN df.[size] ELSE 0 END) * 8.0 / 1024.0 AS decimal(19,2)),
    [TotalAllocatedMB] = CAST(SUM(df.[size]) * 8.0 / 1024.0 AS decimal(19,2)),
    [DataFileCount] = SUM(CASE WHEN df.[type] = 0 THEN 1 ELSE 0 END),
    [LogFileCount] = SUM(CASE WHEN df.[type] = 1 THEN 1 ELSE 0 END),
    [CaptureTime] = SYSDATETIME()
FROM sys.database_files AS df;
GO

PRINT 'SQLSentinel repository maintenance objects created/updated successfully.';
GO
