/*
 SQLSentinel monthly-partitioned, PAGE-compressed history foundation.
 SQL Server 2017 Enterprise. Deploy on SQLMonitoring only.
 IMPORTANT: This script neither deletes raw snapshots nor enables cleanup.
 Partition scheme initially uses PRIMARY; move to dedicated archive filegroup
 only after planning storage and file backups.
*/
USE [SQLMonitoring];
GO
IF SCHEMA_ID(N'rpt') IS NULL EXEC (N'CREATE SCHEMA [rpt] AUTHORIZATION [dbo];');
GO

/* Initialize monthly RANGE RIGHT boundaries: 24 months before this month
   through 24 months after this month. First/last partitions are catchalls.
   The interval [month start, next month start) owns that month. */
IF NOT EXISTS (SELECT 1 FROM sys.partition_functions WHERE [name]=N'pf_SQLSentinelHistory_Month')
BEGIN
    DECLARE @BoundaryDate date = DATEADD(MONTH,-24,DATEFROMPARTS(YEAR(GETDATE()),MONTH(GETDATE()),1));
    DECLARE @LastBoundary date = DATEADD(MONTH,25,DATEFROMPARTS(YEAR(GETDATE()),MONTH(GETDATE()),1));
    DECLARE @BoundaryList nvarchar(max) = N'';
    WHILE @BoundaryDate <= @LastBoundary
    BEGIN
        SET @BoundaryList = @BoundaryList
            + CASE WHEN LEN(@BoundaryList) > 0 THEN N',' ELSE N'' END
            + N'''' + CONVERT(nvarchar(10),@BoundaryDate,23) + N'''';
        SET @BoundaryDate = DATEADD(MONTH,1,@BoundaryDate);
    END;
    EXEC(N'CREATE PARTITION FUNCTION [pf_SQLSentinelHistory_Month] (date) AS RANGE RIGHT FOR VALUES ('+@BoundaryList+N');');
END;
GO
IF NOT EXISTS (SELECT 1 FROM sys.partition_schemes WHERE [name]=N'ps_SQLSentinelHistory_Month')
BEGIN
    EXEC(N'CREATE PARTITION SCHEME [ps_SQLSentinelHistory_Month] AS PARTITION [pf_SQLSentinelHistory_Month] ALL TO ([PRIMARY]);');
END;
GO

/* One rollup row per date, instance, source, and normalized metric.
   Partition-aligned clustered index makes each complete month contiguous.
   Retention and optional partition SWITCH are to be added only after
   independent archive-coverage verification is validated. */
IF OBJECT_ID(N'dbo.SQLSentinelDailyRollup',N'U') IS NULL
BEGIN
    CREATE TABLE [dbo].[SQLSentinelDailyRollup]
    (
        [RollupDate] date NOT NULL,
        [InstanceId] int NULL,
        [SourceTable] varchar(40) NOT NULL,
        [SourceCollector] sysname NULL,
        [MetricCategory] nvarchar(100) NOT NULL,
        [MetricName] nvarchar(200) NOT NULL,
        [SampleCount] bigint NOT NULL,
        [ValueSum] decimal(38,6) NOT NULL,
        [ValueMin] decimal(28,6) NULL,
        [ValueMax] decimal(28,6) NULL,
        [LastCaptureTime] datetime2(0) NULL,
        [ArchivedAt] datetime2(0) NOT NULL
            CONSTRAINT [DF_SQLSentinelDailyRollup_ArchivedAt] DEFAULT (SYSDATETIME())
    ) ON [ps_SQLSentinelHistory_Month]([RollupDate]);

    CREATE CLUSTERED INDEX [CX_SQLSentinelDailyRollup_Month]
        ON [dbo].[SQLSentinelDailyRollup]
        ([RollupDate],[InstanceId],[SourceTable],[MetricCategory],[MetricName])
        WITH (DATA_COMPRESSION = PAGE)
        ON [ps_SQLSentinelHistory_Month]([RollupDate]);
END;
GO
IF OBJECT_ID(N'dbo.SQLSentinelRollupAudit',N'U') IS NULL
BEGIN
    CREATE TABLE [dbo].[SQLSentinelRollupAudit]
    (
        [RollupDate] date NOT NULL,
        [SourceTable] varchar(40) NOT NULL,
        [SourceRows] bigint NOT NULL,
        [SummaryRows] bigint NOT NULL,
        [CompletedAt] datetime2(0) NOT NULL,
        CONSTRAINT [PK_SQLSentinelRollupAudit] PRIMARY KEY CLUSTERED ([RollupDate],[SourceTable])
    );
END;
GO

/* Extend a future boundary when the calendar advances.
   Idempotent. Schedule monthly before a new month begins. */
CREATE OR ALTER PROCEDURE [dbo].[usp_SQLSentinelEnsureArchivePartitions]
    @MonthsAhead int = 24
AS
BEGIN
    SET NOCOUNT ON;
    IF @MonthsAhead NOT BETWEEN 1 AND 60
        THROW 50110,'MonthsAhead must be between 1 and 60.',1;

    DECLARE @Month date = DATEFROMPARTS(YEAR(GETDATE()),MONTH(GETDATE()),1);
    DECLARE @Target date = DATEADD(MONTH,@MonthsAhead+1,@Month);
    DECLARE @Next date = DATEADD(MONTH,1,
    (
        SELECT CONVERT(date,MAX([prv].[value]))
        FROM sys.partition_range_values AS [prv]
        JOIN sys.partition_functions AS [pf]
          ON [pf].[function_id]=[prv].[function_id]
        WHERE [pf].[name]=N'pf_SQLSentinelHistory_Month'
    ));

    WHILE @Next <= @Target
    BEGIN
        ALTER PARTITION SCHEME [ps_SQLSentinelHistory_Month] NEXT USED [PRIMARY];
        DECLARE @Sql nvarchar(max) = N'ALTER PARTITION FUNCTION [pf_SQLSentinelHistory_Month]() SPLIT RANGE ('''
            + CONVERT(nvarchar(10),@Next,23) + N''');';
        EXEC sys.sp_executesql @Sql;
        SET @Next=DATEADD(MONTH,1,@Next);
    END;
END;
GO

/* The historical view includes daily stats and a monthly weighted average.
   The count and sum columns are intentionally retained so SQL Agent events
   can be counted, rather than interpreted as average measurements. */
CREATE OR ALTER VIEW [rpt].[vw_SQLSentinelMonthlyTrends]
AS
SELECT
    DATEFROMPARTS(YEAR([r].[RollupDate]),MONTH([r].[RollupDate]),1) AS [MonthStart],
    [r].[InstanceId],
    [mi].[InstanceName],
    [mi].[EnvironmentName],
    [r].[SourceTable],
    [r].[SourceCollector],
    [r].[MetricCategory],
    [r].[MetricName],
    SUM([r].[SampleCount]) AS [SampleCount],
    CONVERT(decimal(28,6),SUM([r].[ValueSum]) / NULLIF(CONVERT(decimal(38,6),SUM([r].[SampleCount])),0)) AS [AvgValue],
    MIN([r].[ValueMin]) AS [MinValue],
    MAX([r].[ValueMax]) AS [MaxValue],
    SUM([r].[ValueSum]) AS [SumValue],
    MAX([r].[LastCaptureTime]) AS [LastCaptureTime]
FROM [dbo].[SQLSentinelDailyRollup] AS [r]
LEFT JOIN [dbo].[MonitoredInstances] AS [mi]
  ON [mi].[InstanceId]=[r].[InstanceId]
GROUP BY
    DATEFROMPARTS(YEAR([r].[RollupDate]),MONTH([r].[RollupDate]),1),
    [r].[InstanceId],[mi].[InstanceName],[mi].[EnvironmentName],
    [r].[SourceTable],[r].[SourceCollector],[r].[MetricCategory],[r].[MetricName];
GO

CREATE OR ALTER VIEW [rpt].[vw_SQLSentinelArchiveCoverage]
AS
SELECT [RollupDate],[SourceTable],[SourceRows],[SummaryRows],[CompletedAt]
FROM [dbo].[SQLSentinelRollupAudit];
GO

/* Validation query: every populated index partition must be PAGE compressed.
SELECT [p].[partition_number] AS [PartitionNumber],
       [p].[data_compression_desc] AS [Compression],
       [p].[rows] AS [RowCount]
FROM sys.partitions AS [p]
WHERE [p].[object_id]=OBJECT_ID(N'dbo.SQLSentinelDailyRollup')
ORDER BY [p].[partition_number];
*/
