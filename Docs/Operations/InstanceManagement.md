# SQLSentinel Instance Management Runbook

This runbook covers routine operational management of monitored SQL Server instances. Instance state is controlled in `dbo.MonitoredInstances`. Disabling monitoring does not delete historical monitoring data.

## Update local code

Before performing administration tasks, synchronize the local repository:

```powershell
git pull origin main
```

## List monitored instances

All instances:

```powershell
.\Administration\Get-MonitoredInstances.ps1
```

Enabled only:

```powershell
.\Administration\Get-MonitoredInstances.ps1 -Status Enabled
```

Disabled only:

```powershell
.\Administration\Get-MonitoredInstances.ps1 -Status Disabled
```

## Add or update an instance

Use `Register-MonitoredInstance.ps1`. Registration validates connectivity, VIEW SERVER STATE, SQL Agent metadata access, and records SQL version and edition.

SIMPLE backup compliance example:

```powershell
.\Administration\Register-MonitoredInstance.ps1 `
    -SqlInstance "EC-PRD-SQL-35" `
    -EnvironmentName "PROD" `
    -CollectionProfile "Standard" `
    -ComplianceProfile "V1_SIMPLE" `
    -Notes "Production SQL Server"
```

FULL backup compliance example:

```powershell
.\Administration\Register-MonitoredInstance.ps1 `
    -SqlInstance "SERVERNAME" `
    -EnvironmentName "PROD" `
    -CollectionProfile "Standard" `
    -ComplianceProfile "V2_FULL" `
    -Notes "Production SQL Server"
```

`V1_SIMPLE` prevents SQLSentinel from incorrectly requiring transaction log backups for instances intentionally governed by the SIMPLE backup policy. `V2_FULL` applies the FULL recovery backup compliance policy.

## Disable monitoring

Use this for maintenance, troubleshooting, server outages, or when an instance should temporarily stop being collected.

```powershell
.\Administration\Set-MonitoredInstanceState.ps1 `
    -SqlInstance "EC-PRD-SQL-35" `
    -State Disable `
    -Reason "Maintenance window"
```

The operation sets `IsEnabled = 0`. Collectors that select enabled instances will skip the server. Historical rows remain in the repository.

## Re-enable monitoring

```powershell
.\Administration\Set-MonitoredInstanceState.ps1 `
    -SqlInstance "EC-PRD-SQL-35" `
    -State Enable `
    -Reason "Maintenance completed"
```

The operation sets `IsEnabled = 1` and updates `ModifiedAt`.

## Verify state directly in SQL

```sql
SELECT
    InstanceId,
    InstanceName,
    EnvironmentName,
    IsEnabled,
    CollectionProfile,
    ComplianceProfile,
    SqlVersion,
    Edition,
    CreatedAt,
    ModifiedAt,
    Notes
FROM dbo.MonitoredInstances
ORDER BY EnvironmentName, InstanceName;
```

## Validate a newly enabled or registered instance

Run lightweight collectors first and confirm the instance completes successfully:

```powershell
.\Collectors\Collect-PerformanceCounters.ps1
.\Collectors\Collect-Backups.ps1
.\Collectors\Collect-QueryStats.ps1
```

Review recent collector execution history in the SQLMonitoring repository after validation.

## Retirement policy

Do not delete an instance from `dbo.MonitoredInstances` merely because it is retired. Disable it first so historical monitoring data remains associated with the same `InstanceId`.

```powershell
.\Administration\Set-MonitoredInstanceState.ps1 `
    -SqlInstance "SERVERNAME" `
    -State Disable `
    -Reason "Server retired"
```

Permanent deletion should be treated as a separate data-retention operation because repository tables may reference the instance and historical evidence may still be required.

## Operational principles

- Use administration scripts for routine state changes rather than ad-hoc repository updates.
- Preserve historical monitoring data when disabling or retiring an instance.
- Assign the correct backup compliance profile during registration.
- Verify collector execution after adding or re-enabling a server.
- Keep the local repository synchronized with `origin/main` before operational changes.
