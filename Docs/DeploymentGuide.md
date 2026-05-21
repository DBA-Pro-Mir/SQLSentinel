# SQLSentinel Deployment Guide

This guide explains how to deploy the initial SQLSentinel repository database and prepare the jump server for collector execution.

---

# Deployment Scope

The initial deployment creates the central repository database used by SQLSentinel collectors.

The deployment includes:

- SQLMonitoring database
- Core repository tables
- Initial metadata
- Deployment validation

---

# Prerequisites

## Jump Server

The jump server should have:

- Windows Server or workstation with network access to monitored SQL Servers
- PowerShell 5.1 or PowerShell 7
- Git
- dbatools PowerShell module
- SQL Server instance installed locally or accessible remotely

## SQL Server Permissions

The deployment account needs permission to:

- Create database
- Create tables
- Create indexes
- Insert metadata rows

For the prototype, deployment should be run by a DBA or account with sufficient administrative rights.

---

# Install dbatools

Run PowerShell as Administrator:

```powershell
Install-Module dbatools -Scope AllUsers -Force
Import-Module dbatools

# Validate Installation

```powershell
Get-Module dbatools -ListAvailable
```

---

# Clone Repository

```powershell
git clone https://github.com/DBA-Pro-Mir/SQLSentinel.git
cd SQLSentinel
```

---

# Deploy Repository Database

For a default local SQL Server instance:

```powershell
.\Collectors\Deploy-SQLMonitoringRepository.ps1 -CentralSqlInstance "localhost"
```

For a named local SQL Server instance:

```powershell
.\Collectors\Deploy-SQLMonitoringRepository.ps1 -CentralSqlInstance "localhost\SQL2019"
```

For a remote repository SQL Server:

```powershell
.\Collectors\Deploy-SQLMonitoringRepository.ps1 -CentralSqlInstance "SQLMONITOR01"
```

---

# What the Deployment Creates

The deployment script creates:

| Object | Purpose |
| :--- | :--- |
| SQLMonitoring | Central repository database |
| dbo.MonitoredInstances | Inventory of monitored SQL Server instances |
| dbo.CollectionRunHistory | Collector execution history |
| dbo.MetricSnapshot | Generic numeric metric storage |
| dbo.MetricTextSnapshot | Large text/XML metric storage |
| dbo.AnomalyEvents | Detected anomalies and alert events |

---

# Validate Deployment

After deployment, run:

```sql
USE SQLMonitoring;
GO

SELECT name
FROM sys.tables
ORDER BY name;
```

Expected tables:

```plaintext
AnomalyEvents
CollectionRunHistory
MetricSnapshot
MetricTextSnapshot
MonitoredInstances
```

Validate monitored instances:

```sql
SELECT *
FROM dbo.MonitoredInstances;
```

---

# Add Monitored SQL Instances

Example:

```sql
USE SQLMonitoring;
GO

INSERT INTO dbo.MonitoredInstances
(
    InstanceName,
    EnvironmentName,
    CollectionProfile,
    Notes
)
VALUES
(
    'SQLPROD01',
    'Prod',
    'Standard',
    'Production SQL Server'
);
```

---

# Recommended Permissions for Collector Account

Create a service account such as:

```plaintext
DOMAIN\svc_sqlsentinel
```

## Recommended permissions on monitored SQL Servers

| Permission | Purpose |
| :--- | :--- |
| CONNECT SQL | Connect to SQL Server |
| VIEW SERVER STATE | Read DMVs and performance counters |
| VIEW ANY DEFINITION | Optional metadata visibility |
| msdb read access | Backup/job history |

## Recommended permissions on repository database

| Permission | Purpose |
| :--- | :--- |
| db_datareader | Read repository metadata |
| db_datawriter | Insert collected metrics |
| EXECUTE | Run future stored procedures |

---

# Deployment Verification Checklist

- Repository database exists
- Core tables exist
- Deployment script completes without errors
- Local instance is inserted into MonitoredInstances
- dbatools is installed
- Jump server can connect to repository SQL instance
- Jump server can connect to monitored SQL instances
- Git repository is cloned locally

---
# Runtime Configuration and Credentials

SQLSentinel uses two configuration files:

| File | Purpose | Commit to GitHub |
| :--- | :--- | :--- |
| Config/SQLSentinel.config.template.json | Safe template showing required configuration structure | Yes |
| Config/SQLSentinel.config.json | Local runtime configuration with environment-specific values and credentials | No |

The real runtime configuration file should be excluded from Git using `.gitignore`.

Add this to `.gitignore`:

```gitignore
Config/SQLSentinel.config.json
```

---

# SQL Authentication for Prototype Testing

During prototype testing, SQL Authentication can be used when Windows Integrated Authentication is not available or when testing across untrusted domains.

Example local runtime config:

```json
{
  "ProjectName": "SQLSentinel",
  "CentralSqlInstance": "localhost",
  "CentralDatabase": "SQLMonitoring",

  "SqlCredential": {
    "Username": "sqlsentinel",
    "Password": "REPLACE_WITH_LOCAL_PASSWORD"
  },

  "DefaultConnectionTimeoutSeconds": 5,
  "DefaultQueryTimeoutSeconds": 15,
  "CollectorLogPath": "D:\\SQLSentinel\\Logs"
}
```

Do not commit the real password to GitHub.

---

# Required SQL Login on Monitored Servers

For each monitored SQL Server, create or verify the SQL login used by the collectors.

```sql
USE master;
GO

CREATE LOGIN sqlsentinel
WITH PASSWORD = 'REPLACE_WITH_STRONG_PASSWORD';
GO

GRANT VIEW SERVER STATE TO sqlsentinel;
GO
```

If the login already exists:

```sql
USE master;
GO

GRANT VIEW SERVER STATE TO sqlsentinel;
GO
```

`VIEW SERVER STATE` is required for DMV-based collectors such as:

- Performance counters
- Wait stats
- Active requests
- Blocking
- Database IO

---

# Adding a Monitored Server

Add the SQL Server to the central repository:

```sql
USE SQLMonitoring;
GO

INSERT INTO dbo.MonitoredInstances
(
    InstanceName,
    EnvironmentName,
    CollectionProfile,
    Notes
)
VALUES
(
    'EC-DEV-WSD-01',
    'Dev',
    'Standard',
    'Development SQL Server'
);
GO
```

Validate:

```sql
SELECT *
FROM dbo.MonitoredInstances
ORDER BY InstanceName;
```

---

# Testing Multi-Server Collection

Run:

```powershell
.\Collectors\Collect-PerformanceCounters.ps1
```

Expected output:

```plaintext
[INFO] Collecting performance counters from EC-DEV-WSD-01
[INFO] Completed EC-DEV-WSD-01. Rows collected: 62
[INFO] Collecting performance counters from INF-PRD-PVT-01
[INFO] Completed INF-PRD-PVT-01. Rows collected: 53
```
# Next Step

After deployment, create the configuration file:

```plaintext
Config/SQLSentinel.config.json
```

Then build the first collector:

```plaintext
Collectors/Collect-PerformanceCounters.ps1
```
