# SQLSentinel

Enterprise SQL Server monitoring and observability platform built with PowerShell, dbatools, and SQL Server for historical performance analysis, anomaly detection, and incident correlation.
---

# Configuration

SQLSentinel uses a local runtime configuration file:

```plaintext
Config/SQLSentinel.config.json
```

A GitHub-safe template is provided:

```plaintext
Config/SQLSentinel.config.template.json
```

The runtime config may contain credentials and environment-specific settings, so it should not be committed to GitHub.

Collectors currently support SQL Authentication for prototype testing and pass credentials to dbatools using `-SqlCredential`.

---

# Current Prototype Status

Current working prototype features:

- Central monitoring repository
- Multi-server monitoring
- Generic metric ingestion
- Historical metric storage
- Performance counter collection
- Collection execution logging
- SQL authentication support
- dbatools-based connectivity

Current working collectors:

```plaintext
Collectors/Collect-PerformanceCounters.ps1
Collectors/Collect-Connections.ps1
```

Currently monitored metrics include:

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
- TotalUserSessions
- DistinctLogins
- DistinctHosts
- DistinctApplications
- Sessions by login
- Sessions by host
- Sessions by application
- Sessions by database

Connection breakdown metrics use TOP row limits and minimum session thresholds to reduce excessive metric cardinality.

---

# Current Tested Environment

Validated prototype environment:

| Component | Status |
| :--- | :--- |
| Local repository database | Working |
| Multi-server collection | Working |
| Remote SQL collection | Working |
| SQL Authentication | Working |
| dbatools connectivity | Working |
| Historical metric ingestion | Working |


# Current Working Collectors

| Collector | Purpose | Storage |
| :--- | :--- | :--- |
| Collect-PerformanceCounters.ps1 | SQL Server performance counters and throughput metrics | dbo.MetricSnapshot |
| Collect-Connections.ps1 | Connection/session summary and breakdown metrics | dbo.MetricSnapshot |
| Collect-ActiveRequests.ps1 | Threshold-based capture of expensive currently running requests | dbo.MetricSnapshot, dbo.MetricTextSnapshot |
