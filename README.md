# SQLSentinel

SQLSentinel is a SQL Server monitoring and observability platform built with PowerShell, dbatools, and SQL Server. It collects operational, performance, backup, query, blocking, connection, and SQL Agent data into a central repository for historical analysis, incident investigation, reporting, and future health scoring.

## Project Structure

```text
SQLSentinel/
├── Administration/
├── Collectors/
├── Config/
├── Database/
├── Docs/
├── Reports/
└── Samples/
```

## Configuration

SQLSentinel uses a local runtime configuration file:

```text
Config/SQLSentinel.config.json
```

A GitHub-safe template is provided:

```text
Config/SQLSentinel.config.template.json
```

The runtime configuration may contain credentials and environment-specific settings and should not be committed to GitHub.

## Administration

Routine instance operations are performed through the scripts in `Administration/`.

| Script | Purpose |
| --- | --- |
| `Register-MonitoredInstance.ps1` | Register a new monitored SQL Server or refresh an existing registration |
| `Get-MonitoredInstances.ps1` | List all, enabled, or disabled monitored instances |
| `Set-MonitoredInstanceState.ps1` | Enable or disable monitoring while preserving historical data |

### Register an instance

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

Registration validates connectivity and required monitoring access, captures SQL version and edition, and maintains `CreatedAt` and `ModifiedAt` in `dbo.MonitoredInstances`.

### Disable monitoring

```powershell
.\Administration\Set-MonitoredInstanceState.ps1 `
    -SqlInstance "EC-PRD-SQL-35" `
    -State Disable `
    -Reason "Maintenance window"
```

### Re-enable monitoring

```powershell
.\Administration\Set-MonitoredInstanceState.ps1 `
    -SqlInstance "EC-PRD-SQL-35" `
    -State Enable `
    -Reason "Maintenance completed"
```

### List instances

```powershell
.\Administration\Get-MonitoredInstances.ps1
.\Administration\Get-MonitoredInstances.ps1 -Status Enabled
.\Administration\Get-MonitoredInstances.ps1 -Status Disabled
```

## Backup Compliance Profiles

SQLSentinel uses an explicit compliance profile per monitored instance so backup reporting reflects the intended operational policy.

| Profile | Intended Policy |
| --- | --- |
| `V1_SIMPLE` | SIMPLE recovery policy; full backup compliance without transaction log backup requirement |
| `V2_FULL` | FULL recovery policy; full and transaction log backup compliance, with differential checks according to collector configuration |

## Current Collectors

Current collectors include:

- Performance Counters
- Connections
- Active Requests
- Blocking
- Backups
- Database I/O
- Query Stats V2
- Wait Stats
- SQL Agent jobs and alerts where configured

QueryStats V2 uses a bounded candidate model to collect top CPU, duration, logical-read, and execution-count queries without applying expensive SQL text and plan attribute functions to the entire plan cache.

## Documentation

### Operations

- [Instance Management Runbook](Docs/Operations/InstanceManagement.md)
- [Monitored Instance Registration](Docs/Operations/Registration.md)

### Architecture

- [QueryStats Collector V2](docs/architecture/QueryStatsCollector.md)

## Repository Operations

Before performing administration tasks, synchronize the local repository:

```powershell
git status
git pull origin main
```

Routine operational changes should use the administration scripts instead of ad-hoc updates to `dbo.MonitoredInstances`.

## Operational Principles

- Preserve historical data when disabling or retiring an instance.
- Assign the correct backup compliance profile during registration.
- Validate representative collectors after adding or re-enabling an instance.
- Review `dbo.CollectionRunHistory` when troubleshooting collector failures or timeouts.
- Keep collector workloads bounded and lightweight, especially on SQL Server instances with thousands of databases.
