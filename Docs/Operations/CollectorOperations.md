# SQLSentinel Collector Operations Runbook

This runbook covers routine execution, validation, and troubleshooting of SQLSentinel collectors.

## Before running collectors

Run commands from the SQLSentinel repository root and synchronize the local code:

```powershell
cd D:\SQLMonitorRool\SQLSentinel
git status
git pull origin main
```

Confirm the target instance is enabled:

```powershell
.\Administration\Get-MonitoredInstances.ps1 -Status Enabled
```

## Run a collector manually

Collectors can be executed independently from the repository root. Examples:

```powershell
.\Collectors\Collect-PerformanceCounters.ps1
.\Collectors\Collect-Connections.ps1
.\Collectors\Collect-ActiveRequests.ps1
.\Collectors\Collect-Blocking.ps1
.\Collectors\Collect-Backups.ps1
.\Collectors\Collect-DatabaseIO.ps1
.\Collectors\Collect-WaitStats.ps1
.\Collectors\Collect-QueryStats.ps1
```

Manual execution is recommended after onboarding an instance, changing a compliance profile, re-enabling monitoring, or modifying a collector.

## Validate collector output

A normal collector run should identify each enabled instance and report completion or a clear error for each target.

Example:

```text
[INFO] Collecting query stats from SERVERNAME
[INFO] Completed SERVERNAME (71 rows)
```

Do not judge success only from the PowerShell process exit. Review `dbo.CollectionRunHistory` because SQLSentinel collectors can continue to other instances after one target fails.

## Review recent collection history

```sql
SELECT TOP (100)
    crh.CollectionRunId,
    mi.InstanceName,
    crh.CollectorName,
    crh.StartedAt,
    crh.FinishedAt,
    crh.Status,
    crh.RowsCollected,
    crh.DurationMs,
    crh.ErrorMessage
FROM dbo.CollectionRunHistory AS crh
INNER JOIN dbo.MonitoredInstances AS mi
    ON mi.InstanceId = crh.InstanceId
ORDER BY crh.StartedAt DESC;
```

## Find recent failures

Use the administration utility:

```powershell
.\Administration\Get-CollectionFailures.ps1
```

Default scope is the last 24 hours.

Last 72 hours:

```powershell
.\Administration\Get-CollectionFailures.ps1 -Hours 72
```

One server:

```powershell
.\Administration\Get-CollectionFailures.ps1 `
    -SqlInstance "EC-PRD-SQL-35" `
    -Hours 72
```

One collector:

```powershell
.\Administration\Get-CollectionFailures.ps1 `
    -CollectorName "Collect-QueryStats" `
    -Hours 72
```

The utility also reports collection runs that remain in `Running` state beyond the configured age threshold. The default stale-running threshold is 15 minutes.

## Troubleshooting a problematic server

If one monitored instance is unstable, overloaded, or causing repeated collector timeouts, do not repeatedly execute the full collector suite against it.

Temporarily disable the instance:

```powershell
.\Administration\Set-MonitoredInstanceState.ps1 `
    -SqlInstance "SERVERNAME" `
    -State Disable `
    -Reason "Collector troubleshooting"
```

Investigate the SQL Server independently, correct the issue, then re-enable monitoring:

```powershell
.\Administration\Set-MonitoredInstanceState.ps1 `
    -SqlInstance "SERVERNAME" `
    -State Enable `
    -Reason "Collector troubleshooting completed"
```

Run representative collectors afterward and review collection history.

## Timeout handling

A timeout does not automatically mean the collector query is defective. Investigate both sides:

- Current SQL Server CPU and memory pressure
- Blocking and lock waits
- tempdb availability and pressure
- Number of databases or cached plans being inspected
- Collector query complexity
- Configured query timeout
- Network connectivity
- SQL Server service health

Collectors should remain bounded and lightweight. Avoid solving timeouts only by continuously increasing `QueryTimeoutSeconds`.

## High database-count servers

SQLSentinel may monitor SQL Server instances containing hundreds or thousands of databases. Collectors must avoid unnecessary per-database loops and expensive unbounded scans.

Operational warning signs include:

- Collection duration increasing linearly with database count
- Large row counts with little diagnostic value
- tempdb pressure during collection
- Repeated timeout errors on large instances
- A collector returning hundreds or thousands of rows on every short collection interval

When this occurs, review the collector design before increasing collection frequency or timeout values.

## Row-count sanity checks

`RowsCollected` is an important operational signal.

Unexpectedly high counts may indicate over-collection. Unexpected zero counts may indicate either a valid quiet period or a collector/data-processing defect.

Examples from SQLSentinel design:

- QueryStats V2 intentionally limits candidate queries per ranking category.
- Wait statistics should be filtered or bounded rather than storing the entire wait catalog every run.
- Database I/O collection should exclude system databases and avoid unnecessary work on very large database estates.
- Active request capture is threshold-based and may legitimately return no detail rows during quiet periods.

## Zero-row troubleshooting

When a collector unexpectedly reports zero rows:

1. Run the underlying SQL query directly against one target server.
2. Confirm the query returns data.
3. Confirm the PowerShell result type expected by the collector matches the `Invoke-DbaQuery` output mode.
4. Check DataSet table indexes if the query returns multiple result sets.
5. Verify repository inserts are being executed.
6. Review `CollectionRunHistory` for errors hidden by per-instance exception handling.

Do not immediately broaden the SQL query until the PowerShell result-processing path has been validated.

## Common failure patterns

### The wait operation timed out

Treat this as a performance or availability investigation. Check server pressure and collector scope. For large environments, prefer bounded candidate models and server-level DMV queries.

### Property Tables cannot be found

This typically indicates the script expected a DataSet but `Invoke-DbaQuery` returned a different object because execution failed or the output mode was inconsistent. Preserve the original SQL error and validate the object before accessing `.Tables`.

### Missing property on a returned row

Examples include missing `SampleDatabaseName`. This usually means result-set columns and PowerShell property references are out of sync. Compare the SQL SELECT list with the properties consumed by the script.

### SQL Server error 9001 / tempdb unavailable

Stop collector testing against the affected instance and investigate SQL Server health first. A monitoring collector should not be repeatedly executed against a server with an unavailable tempdb log. Disable the instance in SQLSentinel temporarily if needed.

## Post-change validation

After modifying a collector:

1. Test its SQL query directly on a representative server.
2. Test on a small server.
3. Test on a larger or higher database-count server.
4. Run the PowerShell collector manually.
5. Confirm `CollectionRunHistory` status and duration.
6. Confirm `RowsCollected` is reasonable.
7. Verify expected rows in `MetricSnapshot` and/or `MetricTextSnapshot`.
8. Confirm the collector does not introduce material CPU, I/O, blocking, or tempdb pressure.

## Operational policy

- Collectors must target only enabled instances.
- Monitoring must not materially worsen an existing SQL Server incident.
- Prefer bounded queries and top-N/candidate collection patterns.
- Preserve the original target-server error when a collector fails.
- Use `CollectionRunHistory` as the authoritative collector execution audit trail.
- Temporarily disable problematic instances rather than repeatedly stressing them during troubleshooting.
