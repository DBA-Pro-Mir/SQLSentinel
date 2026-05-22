# SQLSentinel Codex Collector Prompt Template

Use this template when asking Codex to create or modify SQLSentinel collectors.

The goal is to make Codex generate collectors that follow SQLSentinel standards for:

- low overhead
- multi-server collection
- safe credential handling
- generic metric storage
- reliable error handling
- maintainable PowerShell
- SQL Server-safe query patterns

---

# How to Use This Template

1. Copy this template.
2. Replace placeholder values such as `<CollectorName>`.
3. Add collector-specific requirements.
4. Submit the prompt to Codex.
5. Review the generated PR carefully.
6. Test locally before merging.

---

# Standard Codex Prompt

```markdown
Create or update:

Collectors/<CollectorName>.ps1

Use the existing collector structure and style from:

- Collectors/Collect-PerformanceCounters.ps1
- Collectors/Collect-Connections.ps1
- Collectors/Collect-ActiveRequests.ps1

Purpose:

<Describe the collector purpose here>

Example:

Capture lightweight SQL Server metrics related to <metric area> without creating unnecessary overhead on monitored SQL Servers.
```

---

# Required Collector Standards

Every collector must:

- Read configuration from `Config/SQLSentinel.config.json`
- Support `SqlCredential`
- Pass `-SqlCredential $SqlCredential` to all `Invoke-DbaQuery` calls
- Read enabled instances from `dbo.MonitoredInstances`
- Loop through each enabled SQL instance
- Log each per-instance run in `dbo.CollectionRunHistory`
- Continue to the next SQL instance if one instance fails
- Use per-instance `try/catch`
- Use `Status = "Success"` for successful runs
- Use `Status = "Failed"` for failed runs
- Avoid modifying database schema unless explicitly requested
- Avoid modifying `Config/SQLSentinel.config.json`
- Avoid collecting excessive detail rows
- Keep the collector lightweight

---

# PowerShell Requirements

Collectors use:

```powershell
Set-StrictMode -Version Latest
```

Because of this, optional configuration values must be checked safely.

Use this pattern:

```powershell
if ($collectorConfig.PSObject.Properties.Name -contains "PropertyName") {
    $Value = [int]$collectorConfig.PropertyName
}
```

Do not use this pattern:

```powershell
if ($null -ne $collectorConfig.PropertyName) {
    $Value = [int]$collectorConfig.PropertyName
}
```

The second pattern fails under `Set-StrictMode` when the property does not exist.

---

# PowerShell String Formatting Rule

Avoid this pattern inside double-quoted strings:

```powershell
"$Variable:"
```

PowerShell may interpret the colon as part of the variable reference.

Use this instead:

```powershell
("Message for {0}: {1}" -f $Variable, $Value)
```

Example:

```powershell
Write-Fail ("Failed for {0}: {1}" -f $TargetInstance, $err)
```

---

# SQL Server CTE Rule

If multiple SQL statements need to reuse the same intermediate result, do not use a CTE across multiple statements.

SQL Server CTEs are valid only for the immediately following statement.

Do not do this:

```sql
WITH ActiveRequests AS
(
    SELECT ...
)
SELECT ... FROM ActiveRequests;

SELECT ... FROM ActiveRequests;
```

The second statement will fail with:

```plaintext
Invalid object name 'ActiveRequests'
```

Use a temporary table instead:

```sql
IF OBJECT_ID('tempdb..#ActiveRequests') IS NOT NULL
    DROP TABLE #ActiveRequests;

SELECT ...
INTO #ActiveRequests
FROM ...;

SELECT ...
FROM #ActiveRequests;

SELECT ...
FROM #ActiveRequests;

DROP TABLE #ActiveRequests;
```

---

# SQL Query Safety Requirements

Collectors should avoid expensive SQL Server activity.

Do not:

- Collect every query
- Collect execution plans unless explicitly requested
- Scan large tables aggressively
- Use broad unfiltered queries
- Run infinite loops
- Store unlimited detail rows
- Capture excessive SQL text

Use:

- Threshold filters
- `TOP` limits
- Summary rows
- Detail capture only when useful
- SQL text truncation
- Lightweight DMVs
- Short query timeouts

---

# Metric Storage Rules

Numeric summary metrics should go to:

```plaintext
dbo.MetricSnapshot
```

Large text/details should go to:

```plaintext
dbo.MetricTextSnapshot
```

Do not create new tables unless explicitly requested.

---

# MetricSnapshot Standards

Use `dbo.MetricSnapshot` for numeric metrics.

Common fields:

| Column | Usage |
| :--- | :--- |
| InstanceId | Monitored instance ID |
| CaptureTime | Metric capture time |
| DatabaseName | Database name if applicable |
| ObjectName | Logical metric object |
| CounterName | Metric name |
| InstanceName | Breakdown value if applicable |
| MetricCategory | Collector/metric category |
| MetricValue | Numeric value |
| MetricType | Gauge, Cumulative, Delta, or Rate |
| Unit | count, ms, sec, MB, percent |
| SourceCollector | Collector script name |

Example:

```plaintext
MetricCategory = ActiveRequest
ObjectName = ActiveRequestSummary
CounterName = ActiveRequestCount
MetricType = Gauge
Unit = count
SourceCollector = Collect-ActiveRequests
```

---

# MetricTextSnapshot Standards

Use `dbo.MetricTextSnapshot` for large details such as:

- SQL text
- blocking details
- deadlock XML
- long-running request evidence
- error details

Common values:

```plaintext
MetricCategory = <Category>
DetailType = <DetailType>
Severity = Warning
SourceCollector = <CollectorName>
```

Use:

```plaintext
NumericValue1
NumericValue2
```

for important numeric fields such as:

- elapsed seconds
- CPU time
- blocking session id
- wait seconds

---

# Cardinality Protection

Collectors must control row growth.

Use protections such as:

```powershell
$MaximumRows = 50
$MinimumThreshold = 2
```

SQL examples:

```sql
SELECT TOP ($MaximumRows)
...
ORDER BY ImportantMetric DESC;
```

For breakdown metrics:

```sql
HAVING COUNT_BIG(1) >= $MinimumThreshold
```

The collector must not generate unbounded metric rows.

---

# SQL Text Protection

If storing SQL text, truncate it.

Use:

```sql
LEFT(CAST(st.text AS nvarchar(max)), 4000)
```

Do not store unlimited query text unless explicitly requested.

Do not collect execution plans unless explicitly requested.

---

# Self-Monitoring Noise Protection

Collectors should avoid capturing SQLSentinel/dbatools activity when collecting active request data.

Use filters like:

```sql
AND ISNULL(s.program_name, '') NOT LIKE '%dbatools%'
AND ISNULL(s.program_name, '') NOT LIKE '%PowerShell%'
AND ISNULL(s.login_name, '') <> 'sqlsentinel'
```

Adjust only if the collector specifically needs to include SQLSentinel activity.

---

# Configuration Defaults

Collectors should use safe defaults if config values are missing.

Example:

```powershell
$QueryTimeout = 10
$MaximumRows = 50
```

Then override only if the config property exists:

```powershell
if ($collectorConfig.PSObject.Properties.Name -contains "MaximumRows") {
    $MaximumRows = [int]$collectorConfig.MaximumRows
}
```

---

# Error Handling Requirements

Collectors must:

- Handle each monitored instance independently
- Log failures in `dbo.CollectionRunHistory`
- Continue to the next instance if one fails
- Avoid stopping the entire collection cycle because one server fails

Use this behavior:

```plaintext
Server A fails
Server B still collects
Server C still collects
```

---

# CollectionRunHistory Standards

Successful collector runs should use:

```plaintext
Status = Success
```

Failed collector runs should use:

```plaintext
Status = Failed
```

Do not use alternate values like:

```plaintext
Succeeded
Complete
Done
```

Keep status values consistent across collectors.

---

# Validation Requirements

After implementation, Codex should provide test commands.

PowerShell test:

```powershell
.\Collectors\<CollectorName>.ps1
```

Metric validation:

```sql
USE SQLMonitoring;
GO

SELECT TOP (100)
    *
FROM dbo.MetricSnapshot
WHERE SourceCollector = '<CollectorName>'
ORDER BY MetricSnapshotId DESC;
```

If using `dbo.MetricTextSnapshot`, also include:

```sql
USE SQLMonitoring;
GO

SELECT TOP (50)
    *
FROM dbo.MetricTextSnapshot
WHERE SourceCollector = '<CollectorName>'
ORDER BY MetricTextSnapshotId DESC;
```

Run history validation:

```sql
USE SQLMonitoring;
GO

SELECT TOP (20)
    *
FROM dbo.CollectionRunHistory
WHERE CollectorName = '<CollectorName>'
ORDER BY CollectionRunId DESC;
```

---

# Do Not Modify

Do not modify:

```plaintext
Config/SQLSentinel.config.json
```

Do not commit secrets.

Do not change database schema unless explicitly requested.

Do not modify existing collectors unless explicitly requested.

---

# PR Description Template

Use this PR description format:

```markdown
# Summary

Adds or updates `<CollectorName>` for SQLSentinel.

# Purpose

Explain what the collector captures and why it is operationally useful.

# Features Added

- Feature 1
- Feature 2
- Feature 3

# Storage

Numeric metrics are stored in:

- dbo.MetricSnapshot

Detailed evidence is stored in:

- dbo.MetricTextSnapshot

# Overhead Controls

This collector avoids excessive overhead by using:

- Thresholds
- TOP limits
- Summary metrics
- Detail capture only when useful
- No execution plans
- Short query timeout

# Validation

Tested with:

```powershell
.\Collectors\<CollectorName>.ps1
```

Validated with:

```sql
SELECT TOP (100)
    *
FROM dbo.MetricSnapshot
WHERE SourceCollector = '<CollectorName>'
ORDER BY MetricSnapshotId DESC;
```

# Schema Changes

No database schema changes.
```

---

# Example Task Prompt

```markdown
Create `Collectors/Collect-DatabaseIO.ps1`.

Use the existing collector structure and SQLSentinel standards.

Purpose:
Capture lightweight database file IO latency metrics using `sys.dm_io_virtual_file_stats`.

Requirements:
- Read config from `Config/SQLSentinel.config.json`
- Support `SqlCredential`
- Read enabled instances from `dbo.MonitoredInstances`
- Use per-instance try/catch
- Log runs in `dbo.CollectionRunHistory`
- Insert numeric metrics into `dbo.MetricSnapshot`
- Use `MetricCategory = DatabaseIO`
- Do not create new tables
- Do not collect excessive detail rows

Important SQL Server rule:
If multiple result sets reuse the same intermediate query, use a temp table, not a CTE across multiple statements.

Do not modify:
- Config/SQLSentinel.config.json
- Existing collectors
- Database schema files

Provide test commands and validation queries.
```