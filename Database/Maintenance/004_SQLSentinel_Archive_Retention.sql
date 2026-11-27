/*
 SQLSentinel historical retention (SQL Server 2017).
 Removes only daily aggregate rows and old audit records after twelve
 complete calendar months, retaining the current partial month.
 This routine never deletes source collector rows.
 Dry-run is the default. No automatic SQL Agent job is created.
*/
USE [SQLMonitoring];
GO
CREATE OR ALTER PROCEDURE [dbo].[usp_SQLSentinelArchiveRetention]
    @CompleteMonthsToKeep int = 12,
    @BatchSize int = 10000,
    @DryRun bit = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @CompleteMonthsToKeep < 12 OR @CompleteMonthsToKeep > 120
        THROW 50170,'CompleteMonthsToKeep must be 12 through 120.',1;
    IF @BatchSize < 100 OR @BatchSize > 50000
        THROW 50171,'BatchSize must be 100 through 50000.',1;

    DECLARE @CutoffDate date=DATEADD(MONTH,-@CompleteMonthsToKeep,
        DATEFROMPARTS(YEAR(GETDATE()),MONTH(GETDATE()),1));

    SELECT N'SQLSentinelDailyRollup' AS [TableName],@CutoffDate AS [CutoffDate],
           COUNT_BIG(*) AS [RowsEligible]
    FROM dbo.SQLSentinelDailyRollup WHERE RollupDate<@CutoffDate
    UNION ALL
    SELECT N'SQLSentinelRollupAudit',@CutoffDate,COUNT_BIG(*)
    FROM dbo.SQLSentinelRollupAudit WHERE RollupDate<@CutoffDate;

    IF @DryRun=1 RETURN;

    /* Do not retire history when old raw records still exist. Otherwise
       their archive audit could be removed before raw cleanup completes. */
    IF EXISTS(SELECT 1 FROM dbo.MetricSnapshot WHERE CaptureTime<@CutoffDate)
        OR EXISTS(SELECT 1 FROM dbo.MetricTextSnapshot WHERE CaptureTime<@CutoffDate)
        OR EXISTS(SELECT 1 FROM dbo.CollectionRunHistory WHERE StartedAt<@CutoffDate)
        OR EXISTS(SELECT 1 FROM dbo.DatabaseCapacitySnapshot WHERE CaptureTime<@CutoffDate)
        OR EXISTS(SELECT 1 FROM dbo.VolumeCapacitySnapshot WHERE CaptureTime<@CutoffDate)
        THROW 50172,'Archive retention blocked: source rows older than cutoff remain.',1;

    DECLARE @LockResult int;
    EXEC @LockResult=sys.sp_getapplock
        @Resource=N'SQLSentinelArchiveDaily',
        @LockMode='Exclusive',@LockOwner='Session',@LockTimeout=0;
    IF @LockResult<0 THROW 50173,'Another archive or cleanup operation is running.',1;

    BEGIN TRY
        DECLARE @Rows int=1;
        WHILE @Rows>0
        BEGIN
            DELETE TOP (@BatchSize) FROM dbo.SQLSentinelDailyRollup
            WHERE RollupDate<@CutoffDate;
            SET @Rows=@@ROWCOUNT;
            IF @Rows>0 WAITFOR DELAY '00:00:00.100';
        END;
        SET @Rows=1;
        WHILE @Rows>0
        BEGIN
            DELETE TOP (@BatchSize) FROM dbo.SQLSentinelRollupAudit
            WHERE RollupDate<@CutoffDate;
            SET @Rows=@@ROWCOUNT;
            IF @Rows>0 WAITFOR DELAY '00:00:00.100';
        END;
        EXEC sys.sp_releaseapplock
            @Resource=N'SQLSentinelArchiveDaily',@LockOwner='Session';
    END TRY
    BEGIN CATCH
        EXEC sys.sp_releaseapplock
            @Resource=N'SQLSentinelArchiveDaily',@LockOwner='Session';
        THROW;
    END CATCH;
END;
GO
