# SQLSentinel Reporting and Repository Retention

## Architecture

SQLSentinel uses the central SQLMonitoring repository as the reporting source. Power BI runs on a separate server and connects only to the SQLMonitoring/pivot SQL Server. Power BI must not connect directly to monitored production SQL Server instances.

```text
Monitored SQL Servers
        |
        | PowerShell/dbatools collectors
        v
SQLMonitoring repository / pivot server
        |
        | rpt reporting views
        v
Power BI server - Import mode
```

## Current refresh model

Collectors currently run approximately twice per day. Power BI should use Import mode and refresh after the collector windows. Refresh frequency can be increased later without changing the reporting architecture when collection becomes more frequent.

## Reporting schema

Run:

```text
Database/Reporting/001_Create_Reporting_Foundation.sql
```

The script creates the `rpt` schema and the initial Power BI reporting views:

- `rpt.vw_InstanceInventory`
- `rpt.vw_MetricLatest`
- `rpt.vw_MetricTrend`
- `rpt.vw_BackupComplianceCurrent`
- `rpt.vw_CollectorHealth`
- `rpt.vw_ServerHealthCurrent`

Power BI should import these views rather than querying the collector tables directly.

## Initial dashboard model

The first dashboard should use `rpt.vw_ServerHealthCurrent` for the executive server scorecard and related views for drill-through analysis.

Initial dashboard pages:

1. SQL Server Health Scorecard
2. Server Detail
3. Query Performance
4. Blocking and Waits
5. Backup Compliance
6. SQL Agent / Operations
7. SQLSentinel Collector and Repository Health

The health model will be expanded as reporting views are added for query, wait, blocking, storage, SQL Agent, CPU, and memory signals.

## Power BI security

Create a dedicated read-only login/user for the Power BI service or gateway identity. Grant access only to the reporting schema where possible.

Example after the login has been created at the SQL Server level:

```sql
USE SQLMonitoring;
GO
CREATE USER [SQLSentinel_PowerBI] FOR LOGIN [SQLSentinel_PowerBI];
GRANT SELECT ON SCHEMA::rpt TO [SQLSentinel_PowerBI];
GO
```

Do not grant broad write access to the repository and avoid granting Power BI direct access to monitored production instances.

## Retention policy

Initial policy while collectors run approximately twice daily:

| Data | Retention |
| --- | ---: |
| `MetricSnapshot` | 90 days |
| `MetricTextSnapshot` | 90 days |
| `CollectionRunHistory` | 365 days |

The policy should be reviewed when collector frequency increases. Raw/high-volume data can use shorter retention while summarized operational history can remain longer.

## Repository cleanup

Run:

```text
Database/Maintenance/001_Create_Repository_Maintenance.sql
```

This creates:

```text
dbo.usp_SQLSentinel_RepositoryCleanup
rpt.vw_RepositoryHealth
```

The cleanup procedure performs batched deletes to reduce transaction log pressure and long blocking transactions.

Default execution:

```sql
EXEC dbo.usp_SQLSentinel_RepositoryCleanup;
```

Explicit example:

```sql
EXEC dbo.usp_SQLSentinel_RepositoryCleanup
    @MetricRetentionDays = 90,
    @TextRetentionDays = 90,
    @CollectionHistoryRetentionDays = 365,
    @BatchSize = 5000,
    @DelayMilliseconds = 100;
```

Review the returned row counts before changing retention values.

## Scheduling maintenance

After the initial manual validation, schedule `dbo.usp_SQLSentinel_RepositoryCleanup` as a SQL Agent job on the SQLMonitoring repository server. Weekly execution is sufficient at the current twice-daily collection frequency. Increase frequency if collection volume grows materially.

Do not schedule cleanup at the same time as the main collector run or Power BI import refresh.

Recommended sequence:

```text
Collectors -> repository settles -> Power BI refresh

Repository cleanup -> separate maintenance window
```

## Repository health

Power BI can import:

```sql
SELECT * FROM rpt.vw_RepositoryHealth;
```

The view exposes allocated data and log size and file counts. Historical repository-growth trending can be added later by collecting these values into SQLSentinel itself.

## Deployment order

1. Pull the latest SQLSentinel repository.
2. Back up SQLMonitoring before the first maintenance deployment.
3. Run `Database/Reporting/001_Create_Reporting_Foundation.sql` in SQLMonitoring.
4. Run `Database/Maintenance/001_Create_Repository_Maintenance.sql` in SQLMonitoring.
5. Validate the `rpt` views manually.
6. Execute the cleanup procedure manually and review its output.
7. Create the Power BI read-only login/user.
8. Test connectivity from the Power BI server to the pivot SQL Server.
9. Configure Power BI Import-mode data sources using the `rpt` views.
10. Schedule cleanup only after manual validation.

## Important safety rule

Do not execute repository cleanup for the first time without a current SQLMonitoring backup. The initial run may delete a larger historical volume than subsequent scheduled runs.
