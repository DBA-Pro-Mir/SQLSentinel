# SQLSentinel Monthly Archive - Development Plan

## Status
The partitioning/compression foundation is committed on feature branch `feature/monthly-history-rollup`. **Do not deploy as a finished archive/retention solution yet.** The data-population procedures, coverage gates, and cleanup integration still require implementation and SQL Server validation.

## Design
- Target database: `SQLMonitoring`, not tenant SQL Server databases.
- Archive table: `dbo.SQLSentinelDailyRollup`, summarized by day and instance/metric dimensions.
- Partition key: `RollupDate` (date), with monthly `RANGE RIGHT` boundaries at the first of each month.
- Partition function: `pf_SQLSentinelHistory_Month`.
- Partition scheme: `ps_SQLSentinelHistory_Month` (currently all partitions in PRIMARY, no new filegroup yet).
- Clustered index: `CX_SQLSentinelDailyRollup_Month`, `DATA_COMPRESSION = PAGE`; partition aligned.
- Coverage table: `dbo.SQLSentinelRollupAudit`.
- Reporting: `rpt.vw_SQLSentinelMonthlyTrends`, `rpt.vw_SQLSentinelArchiveCoverage`.
- Extend future boundaries using `dbo.usp_SQLSentinelEnsureArchivePartitions`.
- Target retention: retain 12 complete calendar months plus the open month; do not delete archive partitions until completed rollups and coverage are verified.

## Still to implement and test
1. Incremental daily upserts/recalculation with correct dimensional keys, event counts, and a rerun-safe transactional audit.
2. Protection against raw cleanup deleting unarchived days. **Existing `dbo.usp_SQLSentinelRepositoryCleanup` has NOT been altered**.
3. Full recovery of historical records still present before enabling any deletion; already purged raw data cannot be reconstructed.
4. Safe monthly partition retirement (switch/truncate versus batch delete) with documented FK, index-alignment, filegroup, and transaction prerequisites.
5. Retention of useful monthly backup compliance snapshots (avoid counting repeated violations as distinct databases).
6. Run SQL Server 2017 syntax checks, controlled dry-runs, boundary verification and page-compression/space checks.

## Safety
Do not schedule archive partition deletion or raw cleanup changes until tests confirm that all expected source rows were summarized and reconciled. Never truncate user or archive tables as a substitute for verified retention operations.
