# SQLSentinel Monitoring Philosophy

SQLSentinel is designed to provide useful SQL Server telemetry without becoming a source of performance overhead.

The goal is not to collect everything. The goal is to collect the right information at the right frequency so DBAs can reconstruct incidents, identify anomalies, and understand performance trends.

---

# Core Philosophy

SQLSentinel should behave like a SQL Server black box recorder.

```plaintext
Small, low-cost metrics collected continuously.
Detailed evidence collected only when thresholds are exceeded.
Historical data preserved for troubleshooting and reporting.
```

---

# Why This Matters

Many performance issues are reported after the fact:

```plaintext
"The system was slow earlier."
"Users complained around 10 AM."
"The application timed out, but now everything looks normal."
```

Point-in-time scripts are not enough because they only show what is happening when the script runs.

SQLSentinel focuses on historical visibility so DBAs can answer:

- What was happening at that time?
- Which server was affected?
- Which database was involved?
- Was there blocking?
- Did waits increase?
- Did IO latency spike?
- Did connections increase?
- Were jobs or backups running?
- Did a configuration change occur?

---

# Lightweight Collection

SQLSentinel should collect lightweight summaries frequently.

Examples:

- Connection counts
- Batch requests/sec
- Blocking count
- Wait stats snapshots
- Database IO snapshots
- Active request summaries
- SQL Agent job status
- Backup status

Heavy details should be collected only when needed.

Examples:

- Full query text
- Execution plans
- Deadlock XML
- Long-running request details
- Error log details

---

# Avoiding Monitoring Overhead

Collectors should avoid:

- Capturing every query
- Capturing every execution plan
- Scanning large system tables frequently
- Running index fragmentation checks frequently
- Querying every database aggressively
- Running expensive Extended Events sessions
- Retrying failed servers too aggressively
- Writing monitoring data locally on production SQL Servers

---

# Centralized Collector Model

Collectors run from the jump server.

Benefits:

- No local agent installed on production SQL Servers
- Easier upgrades
- Centralized scheduling
- Centralized logging
- Easier credential management
- Lower production footprint

---

# Data Collection Principles

Collectors should follow these rules:

1. Use short query timeouts.
2. Log every collector execution.
3. Continue processing if one server fails.
4. Store data in the central repository.
5. Collect cumulative counters as snapshots.
6. Calculate deltas later in reporting/analysis.
7. Avoid unnecessary transformation during collection.
8. Keep collectors simple and predictable.
9. Prefer small frequent snapshots over heavy infrequent scans.
10. Back off or skip expensive collection when the server is under pressure.

---

# Generic Metric Storage

SQLSentinel uses generic metric tables to reduce schema complexity.

Numeric metrics go to:

```plaintext
dbo.MetricSnapshot
```

Large text/XML payloads go to:

```plaintext
dbo.MetricTextSnapshot
```

This allows new collectors to be added without creating a new table for every metric type.

---

# Connection Telemetry Cardinality Control

Connection telemetry is aggregated and filtered to avoid excessive row generation.

Protections include:

- TOP row limits for breakdown metrics
- Minimum session count thresholds
- Aggregated snapshots instead of storing every session row
- Breakdown metrics limited to login, host, application, and database

---

# Database Attribution

A major goal is to identify the database most likely related to slowness or anomalies.

Examples:

- Database with highest IO latency
- Database with blocked requests
- Database with most active expensive requests
- Database with abnormal connection activity
- Database with top wait contribution
- Database with failed backup or job activity

Not every issue can be attributed to a single database.

Some issues are instance-level:

- CPU pressure
- Memory pressure
- TempDB contention
- Worker thread exhaustion
- Server-wide disk latency
- Network issues

When the issue is instance-level, SQLSentinel should report top contributing databases without forcing a false conclusion.

---

# Recommended Collection Frequencies

| Frequency | Metrics |
| :--- | :--- |
| Every 1 minute | Connections, blocking, active requests, throughput counters |
| Every 5 minutes | Wait stats, IO latency, tempdb usage |
| Every 15 minutes | Top queries and expensive workload snapshots |
| Every 1 hour | Backup status and SQL Agent job status |
| Daily | Configuration and inventory |

---

# Alerting Philosophy

Alerts should be actionable.

Avoid noisy alerts such as:

- One-time minor spikes
- Expected maintenance activity
- Known batch windows
- Low-confidence anomalies

Prefer alerts based on:

- Duration
- Severity
- Baseline deviation
- Repeated occurrence
- Business impact
- Correlated evidence

Example:

```plaintext
Bad alert:
CPU is 90%.

Better alert:
CPU pressure was above normal for 12 minutes, batch requests dropped 40%, signal waits increased, and three databases had abnormal active request counts.
```

---

# Long-Term Direction

SQLSentinel should evolve toward:

- Historical trend analysis
- Incident timeline reporting
- Anomaly scoring
- Database attribution
- Root cause evidence
- Low-noise alerting
- Power BI reporting
- Operational diagnostics

The project should remain practical and DBA-focused.
