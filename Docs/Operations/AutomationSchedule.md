# SQLSentinel Automation Schedule

SQLSentinel production automation uses SQL Server Agent on the SQLMonitoring server.

## Recommended schedule

| Process | Schedule | Purpose |
| --- | --- | --- |
| SQLSentinel - Collect All | Every 3 hours at 00:00, 03:00, 06:00, 09:00, 12:00, 15:00, 18:00, 21:00 | Runs the 11 operational collectors |
| SQLSentinel - Daily Storage Capacity | Daily at 05:00 | Captures user-database and user-database-volume capacity |
| SQLSentinel - Repository Cleanup | Daily at 05:30 | Enforces repository retention using batched deletes |
| Power BI semantic model refresh | Approximately 30 minutes after each Collect All run | Refreshes the published Import-mode semantic model |

Do not overlap repository cleanup with the main collector run or a Power BI import refresh.

## SQLSentinel - Collect All

SQL Agent step type:

```text
Operating system (CmdExec)
```

Command:

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "Set-Location 'D:\SQLMonitorRool\SQLSentinel'; & '.\Collectors\Run-AllCollectors.ps1' -ConfigPath '.\Config\SQLSentinel.config.json'"
```

Recommended retry:

```text
Retry attempts: 1
Retry interval: 5 minutes
```

The runner must return a non-zero exit code when any collector fails.

## SQLSentinel - Daily Storage Capacity

SQL Agent step type:

```text
Operating system (CmdExec)
```

Command:

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "Set-Location 'D:\SQLMonitorRool\SQLSentinel'; & '.\Collectors\Run-DailyStorageCapacity.ps1' -ConfigPath '.\Config\SQLSentinel.config.json'"
```

The storage collector intentionally excludes system-database-only volumes. An enabled SQL Server with no user databases is a valid zero-row storage result and must not be treated as a collector failure.

## SQLSentinel - Repository Cleanup

SQL Agent step type:

```text
Transact-SQL script (T-SQL)
```

Database:

```text
SQLMonitoring
```

Command:

```sql
EXEC dbo.usp_SQLSentinelRepositoryCleanup
    @MetricRetentionDays = 30,
    @TextMetricRetentionDays = 60,
    @CollectionRunRetentionDays = 90,
    @DatabaseCapacityRetentionDays = 90,
    @VolumeCapacityRetentionDays = 90,
    @BatchSize = 10000,
    @DryRun = 0;
```

Recommended retry:

```text
Retry attempts: 1
Retry interval: 5 minutes
```

Do not shrink SQLMonitoring after cleanup. Deleted space should remain available for reuse.

## Power BI

The Power BI model should remain in Import mode and use the SQLMonitoring reporting views through the on-premises data gateway.

Recommended refresh times:

```text
00:30
03:30
06:30
09:30
12:30
15:30
18:30
21:30
```

Refresh only after the corresponding collector run has had time to finish.

## Concurrency

SQLMonitoring should have READ_COMMITTED_SNAPSHOT enabled so Power BI readers do not unnecessarily block collector and cleanup writers.

Verify:

```sql
SELECT
    [name],
    [is_read_committed_snapshot_on],
    [snapshot_isolation_state_desc]
FROM sys.databases
WHERE [name] = N'SQLMonitoring';
```

Expected:

```text
is_read_committed_snapshot_on = 1
```
