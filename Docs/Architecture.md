# SQLSentinel Architecture

SQLSentinel is designed as a centralized SQL Server monitoring and observability platform. The goal is to collect lightweight telemetry from multiple SQL Server instances, store historical metrics in a central repository, and support incident analysis, anomaly detection, and long-term reporting.

---

# Architecture Overview

```plaintext
Jump / Monitoring Server
    |
    |-- PowerShell + dbatools collectors
    |
    |-- Local SQL Server Instance
    |      |
    |      |-- SQLMonitoring database
    |             |
    |             |-- MonitoredInstances
    |             |-- CollectionRunHistory
    |             |-- MetricSnapshot
    |             |-- MetricTextSnapshot
    |             |-- AnomalyEvents
    |
    |-- Remote monitored SQL Server instances
```

---

# Main Components

## 1. Jump / Monitoring Server

The jump server is the central execution point for collectors.

Responsibilities:

- Run PowerShell collector scripts
- Use dbatools to connect to monitored SQL Servers
- Schedule collector execution
- Store logs locally
- Write collected metrics to the central repository database

The jump server avoids installing monitoring agents directly on production SQL Servers.

---

## 2. Central Repository Database

The central repository database stores all collected telemetry.

Initial database name:

```plaintext
SQLMonitoring
```

The repository is hosted on the SQL Server instance installed on the jump server.

Core tables:

| Table | Purpose |
| :--- | :--- |
| dbo.MonitoredInstances | Inventory of monitored SQL Server instances |
| dbo.CollectionRunHistory | Collector execution history |
| dbo.MetricSnapshot | Generic numeric metric storage |
| dbo.MetricTextSnapshot | Large text or XML payloads |
| dbo.AnomalyEvents | Detected anomalies and alerts |

---

## 3. PowerShell Collector Layer

Collectors are PowerShell scripts executed from the jump server.

Collectors use:

```plaintext
PowerShell
dbatools
Invoke-DbaQuery
```

The collector layer is responsible for:

- Reading enabled instances from `dbo.MonitoredInstances`
- Connecting to each monitored SQL Server
- Running lightweight DMV or metadata queries
- Transforming results into generic metric rows
- Inserting results into `dbo.MetricSnapshot` or `dbo.MetricTextSnapshot`
- Logging execution results in `dbo.CollectionRunHistory`

Current collectors:

| Collector | Purpose | Frequency | Storage |
| :--- | :--- | :--- | :--- |
| Collect-PerformanceCounters.ps1 | SQL Server performance counters | 1 minute | dbo.MetricSnapshot |
| Collect-Connections.ps1 | Connection/session telemetry | 1 minute | dbo.MetricSnapshot |

Collectors insert telemetry into the generic metric model using these fields:

- MetricCategory
- ObjectName
- CounterName
- InstanceName
- MetricValue
- SourceCollector

---

# Data Flow

```plaintext
1. Scheduled job starts collector script
2. Collector reads enabled SQL instances
3. Collector connects to target SQL Server
4. Collector executes lightweight query
5. Collector formats results as metrics
6. Collector writes metrics to central repository
7. Collector logs success/failure
8. Reports and anomaly logic consume repository data
```

---

# Monitoring Strategy

SQLSentinel uses a lightweight historical collection model.

The system is designed to answer questions such as:

- What was happening when users reported slowness?
- Which database was most likely involved?
- Was there blocking?
- Did waits spike?
- Did IO latency increase?
- Did connections increase?
- Were SQL Agent jobs or backups running?
- Did a configuration change occur?

---

# Collector Design Principles

Collectors must follow these principles:

- Run from the jump server
- Avoid heavy queries on monitored SQL Servers
- Use short query timeouts
- Collect summaries frequently
- Collect details only when thresholds are exceeded
- Write results centrally
- Continue processing other servers if one server fails
- Log every collector run
- Avoid creating load during incidents

---

# Repository Design Philosophy

The prototype intentionally uses a small number of generic tables.

Instead of creating many specialized tables such as:

```plaintext
ConnectionSnapshot
BlockingSnapshot
WaitStatsSnapshot
DatabaseIOSnapshot
PerformanceCounterSnapshot
```

SQLSentinel stores most numeric telemetry in:

```plaintext
dbo.MetricSnapshot
```

Large text/XML payloads are stored in:

```plaintext
dbo.MetricTextSnapshot
```

This reduces schema complexity and makes it easier to add new metrics without creating new tables.

---

# Metric Storage Model

## Numeric Metrics

Stored in:

```plaintext
dbo.MetricSnapshot
```

Examples:

| MetricCategory | CounterName | DatabaseName | MetricValue |
| :--- | :--- | :--- | ---: |
| Connection | TotalUserSessions | NULL | 125 |
| Blocking | BlockedSessionCount | NULL | 3 |
| Wait | LCK_M_S | NULL | 4500 |
| DatabaseIO | AvgReadLatencyMs | SalesDB | 18.5 |
| PerformanceCounter | Batch Requests/sec | NULL | 950 |

---

## Text/XML Metrics

Stored in:

```plaintext
dbo.MetricTextSnapshot
```

Examples:

| MetricCategory | DetailType | Payload |
| :--- | :--- | :--- |
| ActiveRequest | LongRunningQuery | SQL text |
| Deadlock | DeadlockGraph | XML deadlock graph |
| ErrorLog | SevereError | Error log entry |
| JobFailure | AgentJobFailure | Job error details |

---

# Recommended Collection Frequencies

| Frequency | Metrics |
| :--- | :--- |
| Every 1 minute | Connections, blocking, active requests, throughput counters |
| Every 5 minutes | Wait stats, IO latency, tempdb usage |
| Every 15 minutes | Top queries and expensive workload snapshots |
| Every 1 hour | Backups and SQL Agent jobs |
| Daily | Inventory, configuration, and database settings |

---

# Performance and Overhead Controls

SQLSentinel must avoid becoming a source of load.

Controls:

- Use short query timeouts
- Avoid scanning large system tables frequently
- Avoid collecting execution plans every interval
- Avoid collecting every query request
- Store only suspicious active requests
- Collect cumulative counters as snapshots and calculate deltas later
- Use throttling/backoff if a server is under pressure
- Log failures and continue rather than retrying aggressively

---

# Initial Collector Scope

The first collector phase should include:

| Collector | Frequency | Storage |
| :--- | :--- | :--- |
| Performance Counters | 1 minute | MetricSnapshot |
| Connections | 1 minute | MetricSnapshot |
| Blocking | 1 minute | MetricSnapshot / MetricTextSnapshot |
| Wait Stats | 5 minutes | MetricSnapshot |
| Database IO | 5 minutes | MetricSnapshot |
| Active Expensive Requests | 1 minute | MetricTextSnapshot |

---
---

# Authentication Model

SQLSentinel collectors currently support SQL Authentication using credentials defined in the local runtime configuration file.

The collector reads:

```plaintext
Config/SQLSentinel.config.json
```

and creates a PowerShell credential object from:

```json
"SqlCredential": {
  "Username": "sqlsentinel",
  "Password": "REPLACE_WITH_LOCAL_PASSWORD"
}
```

This credential is passed to dbatools using:

```powershell
-SqlCredential $SqlCredential
```

The credential is used for:

- Connecting to the central repository database
- Reading enabled monitored instances
- Connecting to each monitored SQL Server
- Writing collected metrics to the repository

The real config file is local-only and must not be committed to GitHub.

---

# Multi-Server Collection Model

Collectors dynamically read enabled SQL instances from:

```plaintext
dbo.MonitoredInstances
```

This allows SQLSentinel to scale horizontally without modifying collector code.

Example flow:

```plaintext
Collector Start
    |
    |-- Read enabled monitored instances
    |
    |-- Loop through each SQL Server
            |
            |-- Connect
            |-- Collect metrics
            |-- Insert into repository
            |-- Log success/failure
```

Collectors continue processing remaining servers even if one monitored server fails.

---

# Current Working Prototype Components

Currently operational:

| Component | Status |
| :--- | :--- |
| Central repository database | Working |
| Generic metric storage | Working |
| Multi-server collection | Working |
| Performance counter collector | Working |
| SQL authentication support | Working |
| Collection execution logging | Working |
| GitHub repository structure | Working |

Current collector:

```plaintext
Collectors/Collect-PerformanceCounters.ps1
```
# Current Working Collectors

| Collector | Purpose | Storage |
| :--- | :--- | :--- |
| Collect-PerformanceCounters.ps1 | SQL Server performance counters and throughput metrics | dbo.MetricSnapshot |
| Collect-Connections.ps1 | Connection/session summary and breakdown metrics | dbo.MetricSnapshot |
| Collect-ActiveRequests.ps1 | Threshold-based capture of expensive currently running requests | dbo.MetricSnapshot, dbo.MetricTextSnapshot |

Current metrics collected:

- Batch Requests/sec
- User Connections
- Logins/sec
- Logouts/sec
- Transactions/sec
- Lock Waits/sec
- Deadlocks/sec
- SQL Compilations/sec
- SQL Re-Compilations/sec
- Memory metrics
- Buffer metrics
- Page life expectancy
  
# Future Architecture Enhancements

Planned enhancements:

- Baseline engine
- Anomaly scoring
- Incident timeline report
- Extended Events deadlock capture
- Query Store integration
- SQL Agent job runtime analytics
- Backup compliance reporting
- Availability Group monitoring
- Power BI dashboards
- Alerting framework
- Retention and rollup processing

---

# Key Design Decision

SQLSentinel is not intended to collect everything all the time.

The platform should operate like a SQL Server black box recorder:

```plaintext
Small, low-cost metrics collected continuously.
Detailed evidence collected only when useful.
Historical data preserved for incident reconstruction.
```
