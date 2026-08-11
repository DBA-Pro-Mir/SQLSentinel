# SQLSentinel Instance Management Runbook

This runbook defines the routine operational procedures for managing monitored SQL Server instances. Instance state is controlled through `dbo.MonitoredInstances` and the scripts in the `Administration` directory.

Disabling an instance stops normal collector targeting but does not delete the instance or its historical monitoring data.

## Administration utilities

| Script | Purpose |
| --- | --- |
| `Register-MonitoredInstance.ps1` | Add a new instance or refresh an existing registration |
| `Get-MonitoredInstances.ps1` | Display monitored instance inventory and state |
| `Set-MonitoredInstanceState.ps1` | Enable or disable monitoring for an instance |

Detailed onboarding documentation is available in `Docs/Operations/Registration.md`.

## Before making operational changes

Run commands from the repository root:

```powershell
cd D:\SQLMonitorRool\SQLSentinel
```

Synchronize the local repository:

```powershell
git status
git pull origin main
```

Do not pull while an unresolved Git merge is in progress. Resolve or complete the merge first.

## List monitored instances

All instances:

```powershell
.\Administration\Get-MonitoredInstances.ps1
```

Enabled instances only:

```powershell
.\Administration\Get-MonitoredInstances.ps1 -Status Enabled
```

Disabled instances only:

```powershell
.\Administration\Get-MonitoredInstances.ps1 -Status Disabled
```

The inventory includes the environment, enabled state, collection profile, backup compliance profile, SQL version, edition, timestamps, and notes.

## Add a monitored instance

Use `Register-MonitoredInstance.ps1`. Do not manually insert rows into `dbo.MonitoredInstances` for normal onboarding.

SIMPLE backup policy example:

```powershell
.\Administration\Register-MonitoredInstance.ps1 `
    -SqlInstance "EC-PRD-SQL-35" `
    -EnvironmentName "PROD" `
    -CollectionProfile "Standard" `
    -ComplianceProfile "V1_SIMPLE" `
    -Notes "Production SQL Server"
```

FULL backup policy example:

```powershell
.\Administration\Register-MonitoredInstance.ps1 `
    -SqlInstance "SERVERNAME" `
    -EnvironmentName "PROD" `
    -CollectionProfile "Standard" `
    -ComplianceProfile "V2_FULL" `
    -Notes "Production SQL Server"
```

Registration sets `IsEnabled = 1`. It also captures SQL version and edition and updates `ModifiedAt` when an existing registration is refreshed.

See `Registration.md` for prerequisites, validation behavior, repository fields, compliance profile definitions, and troubleshooting.

## Disable monitoring

Disable an instance for maintenance, troubleshooting, prolonged outages, retirement, or whenever collectors should temporarily skip the server.

```powershell
.\Administration\Set-MonitoredInstanceState.ps1 `
    -SqlInstance "EC-PRD-SQL-35" `
    -State Disable `
    -Reason "Maintenance window"
```

Expected repository effect:

```text
IsEnabled = 0
ModifiedAt = current timestamp
```

If a reason is supplied, it is appended to `Notes` to retain operational context.

Historical metrics are not deleted.

## Re-enable monitoring

```powershell
.\Administration\Set-MonitoredInstanceState.ps1 `
    -SqlInstance "EC-PRD-SQL-35" `
    -State Enable `
    -Reason "Maintenance completed"
```

Expected repository effect:

```text
IsEnabled = 1
ModifiedAt = current timestamp
```

After enabling an instance, validate collector execution before considering the server fully returned to monitoring service.

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

To check one instance:

```sql
SELECT *
FROM dbo.MonitoredInstances
WHERE InstanceName = 'EC-PRD-SQL-35';
```

## Validate after registration or re-enablement

Start with representative collectors:

```powershell
.\Collectors\Collect-PerformanceCounters.ps1
.\Collectors\Collect-Backups.ps1
.\Collectors\Collect-QueryStats.ps1
```

Then review recent collection history:

```sql
SELECT TOP (100)
    *
FROM dbo.CollectionRunHistory
ORDER BY StartedAt DESC;
```

Confirm that the instance is being targeted and that collections complete without errors or timeouts.

## Backup compliance profile changes

The backup compliance profile is operationally significant. An incorrect profile can generate false compliance findings.

- `V1_SIMPLE`: SIMPLE backup policy; transaction log backup compliance is not required.
- `V2_FULL`: FULL backup policy; transaction log backup compliance is required.

To change the profile with the current administration tooling, rerun `Register-MonitoredInstance.ps1` for the existing instance using the intended `ComplianceProfile`. The registration script updates the existing row rather than creating a duplicate.

After changing the profile, run:

```powershell
.\Collectors\Collect-Backups.ps1
```

and validate the resulting compliance status.

## Collection profile changes

The current standard collection profile is `Standard`. If an instance needs its collection profile changed, rerun the registration command with the intended `CollectionProfile`. Existing registration metadata will be updated and `ModifiedAt` refreshed.

## Maintenance window procedure

Recommended sequence:

1. Disable the instance using `Set-MonitoredInstanceState.ps1`.
2. Confirm it appears under `Get-MonitoredInstances.ps1 -Status Disabled`.
3. Perform the SQL Server maintenance.
4. Re-enable the instance.
5. Run representative collectors.
6. Review `CollectionRunHistory` for successful execution.

This prevents expected maintenance failures from being treated as monitoring incidents.

## Server retirement procedure

Do not delete a retired server from `dbo.MonitoredInstances` as the normal retirement action.

Disable it:

```powershell
.\Administration\Set-MonitoredInstanceState.ps1 `
    -SqlInstance "SERVERNAME" `
    -State Disable `
    -Reason "Server retired"
```

Keeping the inventory row preserves the `InstanceId` relationship to historical metrics and collection history.

Permanent deletion should be handled separately as a controlled data-retention operation after determining repository dependencies and retention requirements.

## Troubleshooting operational changes

If an administration script fails:

1. Confirm you are running from the SQLSentinel repository root.
2. Confirm `Config/SQLSentinel.config.json` exists.
3. Confirm the `dbatools` module is installed.
4. Confirm connectivity to the central SQLMonitoring repository.
5. Confirm the instance name matches `dbo.MonitoredInstances` exactly.
6. Check the PowerShell error before performing a manual SQL update.

Use direct SQL changes only as an emergency or troubleshooting measure. Routine operations should use the administration scripts so behavior remains repeatable.

## Operational principles

- Use administration scripts instead of ad-hoc repository changes.
- Preserve historical data when disabling or retiring an instance.
- Assign the backup compliance profile according to the intended backup policy.
- Validate collection after adding, changing, or re-enabling an instance.
- Record reasons for operational state changes.
- Keep the local repository synchronized with `origin/main`.
