# SQLSentinel Monthly Archive — Test & Deployment Guide

## Overview

The archive stores **daily aggregate metrics** in a **monthly-partitioned, PAGE-compressed** table. Power BI reads monthly rollups from `rpt.vw_SQLSentinelMonthlyTrends`. Raw collector data retains its existing 30–90 day policy, but cleanup now refuses destructive execution when the archive is missing or stale.

**Scope:** `SQLMonitoring` on the monitoring/pivot SQL instance only. No tenant database schema or backup job is altered. No SQL Agent jobs are created automatically.

**Retention:** 12 complete calendar months plus the current partial month. A separate, disabled-by-default archive-retention procedure deletes aggregate rows older than this period when explicitly called with `@DryRun = 0`. The partitioned table uses RANGE RIGHT, monthly boundaries, PAGE-compressed clustered index, and initially the PRIMARY filegroup. The retention procedure uses batched deletes rather than partition TRUNCATE/SWITCH to avoid accidental loss while boundaries are being validated.

## SQL Server 2017 prerequisites

- Back up `SQLMonitoring` before first deployment.
- Verify SQL Server 2017 Enterprise edition and space/log capacity.
- Deploy scripts in this order from SSMS (execute each complete script against SQLMonitoring):

1. `Database/Maintenance/002_Create_SQLSentinel_Monthly_History.sql` — partition scheme, PAGE-compressed archive, audit, reporting views.
2. `Database/Maintenance/003_SQLSentinel_Archive_Populate_Validate.sql` — daily archive, validation, and date-range backfill procedures.
3. `Database/Maintenance/004_SQLSentinel_Archive_Retention.sql` — *optional*, dry-run-first retirement for >12 complete months.
4. `Database/Maintenance/001_Create_Repository_Maintenance.sql` — **only after** previous scripts are installed; changes raw cleanup to require archive coverage before deleting.

**Important:** Stop/disable the existing SQLSentinel repository cleanup SQL Agent job before altering script 001; do not re-enable until backfill and coverage validation succeed. Existing raw cleanup jobs may already be scheduled separately; inspect them.

## Test sequence — safe

```sql
USE [SQLMonitoring];
GO
-- 1. Confirm archive objects and compression.
SELECT [p].[partition_number] AS [PartitionNumber],
       [p].[data_compression_desc] AS [Compression],
       [p].[rows] AS [RowCount]
FROM sys.partitions AS [p]
WHERE [p].[object_id] = OBJECT_ID(N'dbo.SQLSentinelDailyRollup')
  AND [p].[index_id] = 1
ORDER BY [p].[partition_number];

-- 2. Dry run for yesterday. This shows source row counts ONLY.
DECLARE @Yesterday date = DATEADD(DAY,-1,CONVERT(date,GETDATE()));
EXEC dbo.usp_SQLSentinelArchiveDaily @RollupDate=@Yesterday,@DryRun=1;

-- 3. Execute a single complete day (writes archive only).
EXEC dbo.usp_SQLSentinelArchiveDaily @RollupDate=@Yesterday,@DryRun=0;

-- 4. Check audit counts and monthly reporting.
SELECT * FROM rpt.vw_SQLSentinelArchiveCoverage ORDER BY [RollupDate] DESC,[SourceTable];
SELECT TOP (50) * FROM rpt.vw_SQLSentinelMonthlyTrends ORDER BY [MonthStart] DESC,[InstanceName];

-- 5. Confirm no missing/stale coverage for that date.
EXEC dbo.usp_SQLSentinelValidateArchiveCoverage
    @FromDate=@Yesterday,@ThroughDate=@Yesterday;
```

Backfill **all completed days still available** before raw cleanup. For example, after checking the actual oldest capture dates:

```sql
EXEC dbo.usp_SQLSentinelArchiveBackfill
    @FromDate='2026-11-01',@ThroughDate='2026-11-26',@DryRun=1;

-- Run only after inspecting the dry-run result and assessing row counts:
-- EXEC dbo.usp_SQLSentinelArchiveBackfill
--     @FromDate='2026-11-01',@ThroughDate='2026-11-26',@DryRun=0;
```

Do not assume the example dates apply to your actual dataset.

## Cleanup validation (NO DELETE)

```sql
EXEC dbo.usp_SQLSentinelRepositoryCleanup @DryRun=1;
EXEC dbo.usp_SQLSentinelArchiveRetention @DryRun=1;
```

Cleanup's first result set lists uncovered source days. Empty means no missing coverage for candidate raw deletions. Its next result set shows how many raw rows are eligible for deletion. **Do not use `@DryRun=0` on either procedure until these checks and the month-by-month Power BI trends are verified.**

## Daily operations (after acceptance)

1. Keep the normal collectors unchanged.
2. Archive each **completed day**, rerunning after late-arriving collector records if needed.
3. Confirm `SQLSentinelRollupAudit` has five source entries per archived day.
4. Only then execute guarded raw cleanup in a separate maintenance window.
5. Retire monthly archive aggregates only after 12 complete months, using dry run first.
6. Call `dbo.usp_SQLSentinelEnsureArchivePartitions` monthly for future boundaries.

## Historical fidelity and limitations

- MetricSnapshot is grouped by instance, source collector, category and counter. It does **not** preserve per-database detail or distinguish multiple objects with the same counter within an instance. Averages therefore represent collected metric samples, not necessarily a single server-wide CPU or database total.
- MetricTextSnapshot preserves daily counts by instance, collector, issue type and severity. It does **not** retain SQL text, error messages, XML, or unique affected database identifiers.
- CollectionRunHistory preserves counts of runs grouped by status and collector.
- DatabaseCapacitySnapshot aggregates all database sizes per instance/capture before summarizing. Per-database monthly size history is **not** available in this version.
- VolumeCapacitySnapshot preserves aggregate volume free-space percentage samples; individual volume identity is not retained.
- Monthly `AvgValue` uses weighted samples. For event/count categories use `SumValue` or `SampleCount`, not `AvgValue`.
- Data already deleted by previous retention jobs cannot be reconstructed.
- This implementation requires live validation on SQL Server 2017 before scheduling automated archive or archive-retention jobs.
