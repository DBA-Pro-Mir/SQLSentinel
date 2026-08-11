# SQLSentinel Monitored Instance Registration

This guide documents the current server onboarding process using `Administration/Register-MonitoredInstance.ps1`.

## Purpose

The registration utility performs validation against the target SQL Server instance and then inserts or updates its inventory record in `dbo.MonitoredInstances`.

The script is idempotent: if the instance already exists, it updates the existing row rather than creating a duplicate.

## Prerequisites

Run the command from the SQLSentinel repository root.

```powershell
cd D:\SQLMonitorRool\SQLSentinel
```

Update the local repository first:

```powershell
git pull origin main
```

The following are required:

- `dbatools` PowerShell module
- Access to the SQLSentinel repository database
- Connectivity to the target SQL Server
- `VIEW SERVER STATE` on the target instance
- Read access to SQL Agent metadata in `msdb` for complete job monitoring

## Parameters

| Parameter | Required | Description |
| --- | --- | --- |
| `SqlInstance` | Yes | SQL Server instance name to register |
| `EnvironmentName` | Yes | Environment classification such as PROD, DEV, BETA, or Admin |
| `CollectionProfile` | No | Collector profile. Default is `Standard` |
| `ComplianceProfile` | No | Backup compliance policy. Valid values: `V1_SIMPLE`, `V2_FULL`. Default is `V1_SIMPLE` |
| `Notes` | No | Operational description of the instance |
| `ConfigPath` | No | Path to SQLSentinel runtime configuration |

## Backup compliance profiles

The compliance profile must reflect the intended backup policy rather than making assumptions from the current database recovery model alone.

### V1_SIMPLE

Use when the monitored server is governed by the SIMPLE backup policy.

Expected behavior:

- SIMPLE recovery model is expected
- Full backup compliance is evaluated
- Transaction log backups are not required
- Avoids false alerts for intentionally SIMPLE environments

### V2_FULL

Use when the monitored server is governed by the FULL backup policy.

Expected behavior:

- FULL recovery model is expected
- Full backup compliance is evaluated
- Transaction log backups are required
- Differential backup age is evaluated according to collector configuration

## Registration example: SIMPLE profile

```powershell
.\Administration\Register-MonitoredInstance.ps1 `
    -SqlInstance "EC-PRD-SQL-35" `
    -EnvironmentName "PROD" `
    -CollectionProfile "Standard" `
    -ComplianceProfile "V1_SIMPLE" `
    -Notes "Production SQL Server"
```

## Registration example: FULL profile

```powershell
.\Administration\Register-MonitoredInstance.ps1 `
    -SqlInstance "SERVERNAME" `
    -EnvironmentName "PROD" `
    -CollectionProfile "Standard" `
    -ComplianceProfile "V2_FULL" `
    -Notes "Production SQL Server"
```

## Validation performed during registration

The registration script currently validates and reports:

- SQL connectivity
- SQL Server product version
- SQL Server edition
- Number of online user databases
- CPU count
- Physical memory
- `VIEW SERVER STATE` permission
- SQL Agent metadata access in `msdb`

A failure of the mandatory connectivity or `VIEW SERVER STATE` validation stops registration.

A failure of SQL Agent metadata validation generates a warning and registration continues. SQL Agent related collectors may fail until the required `msdb` permissions are granted.

## Repository fields populated

The registration process maintains the following fields in `dbo.MonitoredInstances`:

- `InstanceName`
- `EnvironmentName`
- `IsEnabled`
- `CollectionProfile`
- `ComplianceProfile`
- `SqlVersion`
- `Edition`
- `Notes`
- `CreatedAt`
- `ModifiedAt`

For a newly registered instance, `CreatedAt` and `ModifiedAt` are populated. For an existing instance, `ModifiedAt` is refreshed and the operational metadata is updated.

## Verify registration

Use the administration utility:

```powershell
.\Administration\Get-MonitoredInstances.ps1
```

Or verify directly in SQL:

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
    Notes,
    CreatedAt,
    ModifiedAt
FROM dbo.MonitoredInstances
WHERE InstanceName = 'EC-PRD-SQL-35';
```

## Post-registration validation

Run representative collectors after onboarding:

```powershell
.\Collectors\Collect-PerformanceCounters.ps1
.\Collectors\Collect-Backups.ps1
.\Collectors\Collect-QueryStats.ps1
```

Confirm that the new instance completes successfully and review `dbo.CollectionRunHistory` for failures or timeouts.

## Common registration errors

### VIEW SERVER STATE missing

Registration stops because core collectors depend on DMVs requiring `VIEW SERVER STATE`.

### SQL Agent metadata warning

Registration succeeds, but SQL Agent job monitoring may fail. Grant the monitoring identity the required `msdb` read access before considering onboarding complete.

### Invalid repository column

The registration script expects the current `dbo.MonitoredInstances` schema, including:

- `ComplianceProfile`
- `SqlVersion`
- `Edition`
- `ModifiedAt`

If one is missing, update the SQLSentinel repository schema before registering additional instances.

## Operational policy

Registration enables monitoring by setting `IsEnabled = 1`. To temporarily stop collection, do not delete the instance. Use `Set-MonitoredInstanceState.ps1` so historical monitoring data remains associated with the same `InstanceId`.
