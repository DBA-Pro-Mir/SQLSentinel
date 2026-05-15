# SQLSentinel Roadmap

This roadmap defines the planned evolution of SQLSentinel from prototype to enterprise monitoring platform.

The roadmap is intentionally incremental. Each phase should produce a working, useful deliverable before moving to the next phase.

---

# Phase 1 — Repository Foundation

## Goal

Create the central repository and establish the project structure.

## Deliverables

- GitHub repository
- Folder structure
- README
- Architecture documentation
- Deployment guide
- Repository deployment script
- PowerShell deployment script
- Core repository tables

## Core Tables

- dbo.MonitoredInstances
- dbo.CollectionRunHistory
- dbo.MetricSnapshot
- dbo.MetricTextSnapshot
- dbo.AnomalyEvents

## Status

```plaintext
In progress
```

---

# Phase 2 — Core Collectors

## Goal

Collect the first low-overhead metrics from monitored SQL Servers.

## Initial Collectors

| Collector | Frequency | Storage |
| :--- | :--- | :--- |
| Performance counters | 1 minute | MetricSnapshot |
| Connections | 1 minute | MetricSnapshot |
| Blocking | 1 minute | MetricSnapshot |
| Wait stats | 5 minutes | MetricSnapshot |
| Database IO | 5 minutes | MetricSnapshot |
| Active expensive requests | 1 minute | MetricTextSnapshot |

## Success Criteria

- Metrics are collected from at least one remote SQL Server.
- Metrics are inserted into the central repository.
- Collector runs are logged.
- Failed servers do not stop the full collection cycle.

---

# Phase 3 — Incident Analysis

## Goal

Provide the ability to reconstruct a slowness incident after it happened.

## Deliverables

- Incident timeline stored procedure
- Incident summary query
- Database attribution logic
- Blocking timeline
- Wait stats timeline
- IO latency timeline
- Connection trend
- Active request evidence

## Example Question

```plaintext
What was happening on SQLPROD01 between 10:00 AM and 10:30 AM?
```

## Expected Output

- Top abnormal metrics
- Blocking evidence
- Wait spikes
- IO latency changes
- Most likely affected database
- Long-running requests
- Related job or backup activity

---

# Phase 4 — Configuration and Change Tracking

## Goal

Track SQL Server and database configuration changes over time.

## Metrics

- sys.configurations
- SQL Server version/patch level
- Trace flags
- Database options
- Compatibility level
- Recovery model
- Query Store status
- Max server memory
- MAXDOP
- Cost threshold for parallelism
- TempDB file configuration

## Success Criteria

- Configuration changes are detected.
- Change history can be reported.
- Risky configuration changes can create anomaly events.

---

# Phase 5 — Extended Events Integration

## Goal

Capture events that DMVs do not preserve well.

## Initial XE Sessions

- Deadlocks
- Long-running queries above threshold
- Severe errors
- Blocked process reports, if enabled

## Design Rule

Extended Events must be threshold-based and narrow in scope.

Avoid capturing every batch, RPC, or statement.

---

# Phase 6 — Anomaly Detection

## Goal

Detect abnormal behavior using historical baselines.

## Initial Rules

- Connections above normal baseline
- Blocking persisting longer than threshold
- IO latency above threshold
- Wait stats above normal baseline
- Job runtime above normal baseline
- Missing or delayed backups
- Configuration changes

## Future Enhancements

- Hour-of-day baselines
- Day-of-week baselines
- Confidence scoring
- Alert suppression
- Maintenance windows
- Severity classification

---

# Phase 7 — Reporting

## Goal

Provide operational and management reports.

## Initial Reports

- Server health timeline
- Connection trend
- Blocking trend
- Top waits
- Database IO latency
- Backup compliance
- SQL Agent job failures
- Configuration change history
- Anomaly summary

## Tools

- Power BI
- SSRS
- SQL queries
- Future web dashboard

---

# Phase 8 — Enterprise Features

## Goal

Add features needed for broader production use.

## Planned Features

- Availability Group monitoring
- Log shipping monitoring
- SQL Agent timeline
- Retention and rollups
- Alert routing
- Maintenance windows
- Collector profiles
- Security hardening
- Web/API layer
- Forecasting

---

# Guiding Principle

Do not build every feature at once.

Each phase should remain:

- Lightweight
- Testable
- Useful
- Documented
- Low overhead
- Operationally valuable