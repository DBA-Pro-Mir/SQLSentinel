# QueryStats Collector (V2)

## Overview

The QueryStats collector identifies the most resource-intensive cached queries executed during a configurable lookback period while minimizing overhead on monitored SQL Server instances.

## Design Goals

- Predictable execution time
- Minimal impact on monitored servers
- Scalable to environments with thousands of databases
- Avoid scanning the entire plan cache
- Capture only actionable query statistics

## Collection Workflow

1. Read configuration.
2. Get enabled monitored instances.
3. Start a CollectionRunHistory record.
4. Select Top N candidate queries by CPU, Duration, Logical Reads, and Execution Count.
5. Deduplicate candidates by RankingCategory, QueryHash, and QueryPlanHash.
6. Retrieve SQL text and database attributes only for deduplicated candidates.
7. Filter SQLSentinel internal queries.
8. Store summary metrics in MetricSnapshot.
9. Store detailed query information in MetricTextSnapshot.
10. Complete CollectionRunHistory.

## Candidate Selection

The collector retrieves the configurable Top N queries in each category:

- CPU
- Duration
- Logical Reads
- Execution Count

Default configuration:

```json
{
  "Collectors": {
    "QueryStats": {
      "TopQueriesPerCategory": 25,
      "LookbackMinutes": 60,
      "MaxSqlTextLength": 1000,
      "MinimumExecutionCount": 1,
      "QueryTimeoutSeconds": 120
    }
  }
}
```

With the default configuration, the collector evaluates at most 100 candidate queries before deduplication.

## Improvements in V2

- Candidate-based collection instead of scanning the full plan cache.
- Deferred SQL text retrieval.
- Deferred plan attribute retrieval.
- Deduplication using QueryHash and QueryPlanHash.
- Configurable collection limits.
- Five-second LOCK_TIMEOUT protection.
- Predictable execution time across small and large SQL Server environments.

## Validation Results

Validated against:

- EC-DEV-WSD-01
- EC-PRD-SQL-32
- EC-PRD-SQL-33
- EC-PRD-SQL-34
- INF-PRD-PVT-01
- WE-BETA-SQL-01

The previous timeout on EC-PRD-SQL-33 was eliminated after implementing the V2 architecture.
