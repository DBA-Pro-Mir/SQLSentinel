/*
 SQLSentinel archive read-only verification.
 Run in SQLMonitoring after installing scripts 002,003,004.
 No data is changed.
*/
USE [SQLMonitoring];
GO
SELECT [p].[partition_number] AS [PartitionNumber],
       [p].[data_compression_desc] AS [Compression],
       [p].[rows] AS [RowCount],
       [fg].[name] AS [FilegroupName]
FROM sys.partitions AS [p]
JOIN sys.indexes AS [i]
  ON [i].[object_id]=[p].[object_id] AND [i].[index_id]=[p].[index_id]
JOIN sys.destination_data_spaces AS [dds]
  ON [dds].[partition_scheme_id]=[i].[data_space_id]
 AND [dds].[destination_id]=[p].[partition_number]
JOIN sys.filegroups AS [fg] ON [fg].[data_space_id]=[dds].[data_space_id]
WHERE [p].[object_id]=OBJECT_ID(N'dbo.SQLSentinelDailyRollup')
  AND [p].[index_id]=1
ORDER BY [p].[partition_number];
GO

SELECT [pf].[name] AS [PartitionFunction],[pf].[boundary_value_on_right] AS [RangeRight],
       CONVERT(date,[prv].[value]) AS [Boundary]
FROM sys.partition_functions AS [pf]
JOIN sys.partition_range_values AS [prv]
  ON [pf].[function_id]=[prv].[function_id]
WHERE [pf].[name]=N'pf_SQLSentinelHistory_Month'
ORDER BY [prv].[boundary_id];
GO

SELECT [RollupDate],[SourceTable],[SourceRows],[SummaryRows],
       [MaxSourceId],[CompletedAt]
FROM [rpt].[vw_SQLSentinelArchiveCoverage]
ORDER BY [RollupDate] DESC,[SourceTable];
GO

SELECT TOP (100)
    [MonthStart],[InstanceName],[SourceTable],[SourceCollector],
    [MetricCategory],[MetricName],[SampleCount],
    [AvgValue],[MinValue],[MaxValue],[SumValue],[LastCaptureTime]
FROM [rpt].[vw_SQLSentinelMonthlyTrends]
ORDER BY [MonthStart] DESC,[InstanceName],[SourceTable],[MetricCategory];
GO

/* Archive rows by calendar month and source; no full raw-data expansion. */
SELECT DATEFROMPARTS(YEAR([RollupDate]),MONTH([RollupDate]),1) AS [MonthStart],
       [SourceTable],SUM([SampleCount]) AS [SampleCount],
       COUNT_BIG(*) AS [SummaryRows]
FROM dbo.SQLSentinelDailyRollup
GROUP BY DATEFROMPARTS(YEAR([RollupDate]),MONTH([RollupDate]),1),[SourceTable]
ORDER BY [MonthStart] DESC,[SourceTable];
GO

/* Both procedures are safe by default. */
EXEC dbo.usp_SQLSentinelArchiveRetention @DryRun=1;
EXEC dbo.usp_SQLSentinelRepositoryCleanup @DryRun=1;
GO
