# SQLSentinel Design Decisions

This document records key design decisions for SQLSentinel so the project remains understandable and maintainable over time.

---

# Decision 1 — Use a Centralized Collector Model

## Decision

Collectors will run from the jump/monitoring server instead of being installed on every monitored SQL Server.

## Reason

This reduces production footprint and simplifies management.

## Benefits

- No agent deployment to production SQL Servers
- Easier upgrades
- Centralized scheduling
- Centralized logging
- Easier security control
- Lower operational overhead

---

# Decision 2 — Use PowerShell and dbatools

## Decision

The collector framework will use PowerShell and dbatools.

## Reason

The team is comfortable with PowerShell and dbatools provides mature SQL Server automation functions.

## Benefits

- Faster development
- Easier multi-server execution
- Better SQL connection handling
- Built-in SQL Server helper commands
- Good fit for DBA workflows

---

# Decision 3 — Store Metrics in SQL Server

## Decision

The central repository will be a SQL Server database.

## Reason

SQL Server is already part of the operational environment and is familiar to the DBA team.

## Benefits

- Easy querying with T-SQL
- Easy integration with Power BI and SSRS
- Familiar backup/security model
- Good fit for historical operational data
- No additional platform required for prototype

---

# Decision 4 — Use Generic Metric Tables

## Decision

Use a small number of generic tables instead of many specialized snapshot tables.

Primary tables:

- dbo.MetricSnapshot
- dbo.MetricTextSnapshot

## Reason

Too many specialized tables increase maintenance, schema changes, and collector complexity.

## Benefits

- Easier to add new metrics
- Lower schema maintenance
- Simpler ingestion pattern
- More flexible reporting model
- Better prototype velocity

## Trade-Off

Generic tables may require views or reporting logic to shape data for specific use cases.

---

# Decision 5 — Keep Heavy Payloads Separate

## Decision

Large text and XML payloads will be stored in `dbo.MetricTextSnapshot`, not in the primary numeric metric table.

## Reason

Query text, deadlock XML, and error details can be large and should not bloat numeric metric storage.

## Benefits

- Keeps numeric metrics lean
- Improves query performance for time-series metrics
- Allows selective collection of heavy evidence
- Separates high-volume and low-volume data patterns

---

# Decision 6 — Avoid Heavy Collection by Default

## Decision

SQLSentinel will not collect everything all the time.

## Reason

Monitoring should not become the cause of performance degradation.

## Examples of Avoided Behavior

- Capturing every query
- Capturing every execution plan
- Running index fragmentation frequently
- Scanning all databases aggressively
- Running broad Extended Events sessions
- Collecting full query text every minute

## Preferred Approach

- Collect summaries frequently
- Collect details only when thresholds are exceeded
- Use deltas from cumulative counters
- Use short timeouts
- Skip or back off when servers are under pressure

---

# Decision 7 — Use Historical Snapshots

## Decision

Collectors will store historical snapshots instead of only current state.

## Reason

Most performance complaints are reported after the issue has already passed.

## Benefit

This allows incident reconstruction.

Example:

```plaintext
Users reported slowness between 10:00 AM and 10:30 AM.
SQLSentinel should show what happened during that window.
```

---

# Decision 8 — Prioritize Database Attribution

## Decision

Where possible, metrics should include `DatabaseName`.

## Reason

DBAs often need to identify which database or workload contributed to the issue.

## Examples

- Database IO latency
- Active requests by database
- Blocking by database
- Query workload by database
- Backup/job failures by database

## Limitation

Some issues are instance-level and cannot be accurately assigned to one database.

---

# Decision 9 — Query Store Is Optional

## Decision

SQLSentinel will not require Query Store to be enabled everywhere.

## Reason

Not all databases have Query Store enabled.

## Approach

- Use Query Store where enabled
- Use plan cache DMVs as fallback
- Use Extended Events for selected events
- Do not force Query Store rollout during prototype

---

# Decision 10 — Extended Events Should Be Targeted

## Decision

Extended Events will be used only for targeted scenarios.

## Initial XE Use Cases

- Deadlocks
- Long-running queries above threshold
- Severe errors
- Blocked process reports, if enabled

## Reason

Broad Extended Events sessions can generate overhead and excessive data.

---

# Decision 11 — Build Incrementally

## Decision

SQLSentinel will be built in phases.

## Reason

Monitoring platforms can become too large and complex if everything is built at once.

## Initial Focus

- Repository
- Performance counters
- Connections
- Blocking
- Wait stats
- Database IO
- Active expensive requests

## Later Focus

- Anomaly detection
- Incident timeline
- Power BI dashboards
- Alerting
- Availability Groups
- Retention and rollups

---

# Decision 12 — Documentation Lives With the Code

## Decision

Project documentation will be stored in the GitHub repository under `Docs/`.

## Reason

Design decisions, deployment steps, and operational notes should be versioned with the project.

## Benefits

- Easier long-term maintenance
- Better project continuity
- Clear history of decisions
- Easier onboarding
- Reduced dependency on chat history