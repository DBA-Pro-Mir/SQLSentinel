/*=============================================================================
  SQL Monitoring Tool - Repository Database Deployment Script
  Project: SQL Monitoring Tool
  Purpose:
      Creates the central SQLMonitoring repository database and core prototype
      tables used by the PowerShell/dbatools collectors.

  Notes:
      - Designed for the SQL Server instance located on the jump/monitoring server.
      - Uses a small generic schema to reduce maintenance and avoid many tables.
      - This script is safe to run multiple times.
      - Existing tables are not dropped.
=============================================================================*/

USE master;
GO

IF DB_ID(N'SQLMonitoring') IS NULL
BEGIN
    PRINT 'Creating database SQLMonitoring...';
    CREATE DATABASE SQLMonitoring;
END
ELSE
BEGIN
    PRINT 'Database SQLMonitoring already exists.';
END
GO

USE SQLMonitoring;
GO

/*=============================================================================
  dbo.MonitoredInstances
=============================================================================*/

IF OBJECT_ID(N'dbo.MonitoredInstances', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.MonitoredInstances
    (
        InstanceId int IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_MonitoredInstances PRIMARY KEY,

        InstanceName sysname NOT NULL,

        EnvironmentName varchar(20) NULL,

        IsEnabled bit NOT NULL
            CONSTRAINT DF_MonitoredInstances_IsEnabled DEFAULT (1),

        CollectionProfile varchar(30) NOT NULL
            CONSTRAINT DF_MonitoredInstances_CollectionProfile DEFAULT ('Standard'),

        SqlVersion nvarchar(100) NULL,

        Edition nvarchar(200) NULL,

        Notes nvarchar(1000) NULL,

        CreatedAt datetime2(0) NOT NULL
            CONSTRAINT DF_MonitoredInstances_CreatedAt DEFAULT (sysdatetime()),

        ModifiedAt datetime2(0) NULL
    );

    CREATE UNIQUE INDEX IX_MonitoredInstances_InstanceName
    ON dbo.MonitoredInstances(InstanceName);

    PRINT 'Created dbo.MonitoredInstances.';
END
ELSE
BEGIN
    PRINT 'dbo.MonitoredInstances already exists.';
END
GO

/*=============================================================================
  dbo.CollectionRunHistory
=============================================================================*/

IF OBJECT_ID(N'dbo.CollectionRunHistory', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.CollectionRunHistory
    (
        CollectionRunId bigint IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_CollectionRunHistory PRIMARY KEY,

        CollectorName sysname NOT NULL,

        InstanceId int NULL,

        StartedAt datetime2(0) NOT NULL,

        FinishedAt datetime2(0) NULL,

        Status varchar(20) NOT NULL,

        RowsCollected int NULL,

        DurationMs int NULL,

        ErrorMessage nvarchar(max) NULL,

        CreatedAt datetime2(0) NOT NULL
            CONSTRAINT DF_CollectionRunHistory_CreatedAt DEFAULT (sysdatetime())
    );

    CREATE INDEX IX_CollectionRunHistory_StartedAt
    ON dbo.CollectionRunHistory(StartedAt);

    CREATE INDEX IX_CollectionRunHistory_InstanceId
    ON dbo.CollectionRunHistory(InstanceId, StartedAt);

    PRINT 'Created dbo.CollectionRunHistory.';
END
ELSE
BEGIN
    PRINT 'dbo.CollectionRunHistory already exists.';
END
GO

/*=============================================================================
  dbo.MetricSnapshot
  Generic numeric time-series metrics table.
=============================================================================*/

IF OBJECT_ID(N'dbo.MetricSnapshot', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.MetricSnapshot
    (
        MetricSnapshotId bigint IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_MetricSnapshot PRIMARY KEY,

        InstanceId int NOT NULL,

        CaptureTime datetime2(0) NOT NULL,

        DatabaseName sysname NULL,

        ObjectName nvarchar(128) NULL,

        CounterName nvarchar(200) NOT NULL,

        InstanceName nvarchar(128) NULL,

        MetricCategory varchar(50) NOT NULL,

        MetricValue decimal(28,6) NOT NULL,

        MetricType varchar(30) NULL,

        Unit varchar(30) NULL,

        SourceCollector sysname NOT NULL,

        CreatedAt datetime2(0) NOT NULL
            CONSTRAINT DF_MetricSnapshot_CreatedAt DEFAULT (sysdatetime())
    );

    CREATE INDEX IX_MetricSnapshot_Instance_CaptureTime
    ON dbo.MetricSnapshot(InstanceId, CaptureTime);

    CREATE INDEX IX_MetricSnapshot_Category_Counter
    ON dbo.MetricSnapshot(MetricCategory, CounterName, CaptureTime);

    CREATE INDEX IX_MetricSnapshot_DatabaseName
    ON dbo.MetricSnapshot(DatabaseName, CaptureTime);

    CREATE INDEX IX_MetricSnapshot_CaptureTime
    ON dbo.MetricSnapshot(CaptureTime);

    PRINT 'Created dbo.MetricSnapshot.';
END
ELSE
BEGIN
    PRINT 'dbo.MetricSnapshot already exists.';
END
GO

/*=============================================================================
  dbo.MetricTextSnapshot
  Stores heavier payloads such as active request text, deadlock XML, errors, etc.
=============================================================================*/

IF OBJECT_ID(N'dbo.MetricTextSnapshot', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.MetricTextSnapshot
    (
        MetricTextSnapshotId bigint IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_MetricTextSnapshot PRIMARY KEY,

        InstanceId int NOT NULL,

        CaptureTime datetime2(0) NOT NULL,

        DatabaseName sysname NULL,

        MetricCategory varchar(50) NOT NULL,

        DetailType varchar(50) NOT NULL,

        Severity varchar(20) NULL,

        NumericValue1 decimal(28,6) NULL,

        NumericValue2 decimal(28,6) NULL,

        Details nvarchar(max) NULL,

        XmlDetails xml NULL,

        SourceCollector sysname NOT NULL,

        CreatedAt datetime2(0) NOT NULL
            CONSTRAINT DF_MetricTextSnapshot_CreatedAt DEFAULT (sysdatetime())
    );

    CREATE INDEX IX_MetricTextSnapshot_Instance_CaptureTime
    ON dbo.MetricTextSnapshot(InstanceId, CaptureTime);

    CREATE INDEX IX_MetricTextSnapshot_Category
    ON dbo.MetricTextSnapshot(MetricCategory, CaptureTime);

    CREATE INDEX IX_MetricTextSnapshot_DatabaseName
    ON dbo.MetricTextSnapshot(DatabaseName, CaptureTime);

    PRINT 'Created dbo.MetricTextSnapshot.';
END
ELSE
BEGIN
    PRINT 'dbo.MetricTextSnapshot already exists.';
END
GO

/*=============================================================================
  dbo.AnomalyEvents
=============================================================================*/

IF OBJECT_ID(N'dbo.AnomalyEvents', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.AnomalyEvents
    (
        AnomalyEventId bigint IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_AnomalyEvents PRIMARY KEY,

        InstanceId int NOT NULL,

        DatabaseName sysname NULL,

        MetricCategory varchar(50) NOT NULL,

        CounterName nvarchar(200) NOT NULL,

        Severity varchar(20) NOT NULL,

        CurrentValue decimal(28,6) NULL,

        BaselineValue decimal(28,6) NULL,

        ThresholdValue decimal(28,6) NULL,

        ConfidenceScore decimal(5,2) NULL,

        Details nvarchar(max) NULL,

        DetectedAt datetime2(0) NOT NULL
            CONSTRAINT DF_AnomalyEvents_DetectedAt DEFAULT (sysdatetime()),

        IsAcknowledged bit NOT NULL
            CONSTRAINT DF_AnomalyEvents_IsAcknowledged DEFAULT (0),

        AcknowledgedAt datetime2(0) NULL,

        AcknowledgedBy nvarchar(128) NULL
    );

    CREATE INDEX IX_AnomalyEvents_DetectedAt
    ON dbo.AnomalyEvents(DetectedAt);

    CREATE INDEX IX_AnomalyEvents_InstanceId
    ON dbo.AnomalyEvents(InstanceId, DetectedAt);

    CREATE INDEX IX_AnomalyEvents_Severity
    ON dbo.AnomalyEvents(Severity, DetectedAt);

    PRINT 'Created dbo.AnomalyEvents.';
END
ELSE
BEGIN
    PRINT 'dbo.AnomalyEvents already exists.';
END
GO

/*=============================================================================
  Optional seed row for the local jump server SQL instance.
=============================================================================*/

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.MonitoredInstances
    WHERE InstanceName = @@SERVERNAME
)
BEGIN
    INSERT INTO dbo.MonitoredInstances
    (
        InstanceName,
        EnvironmentName,
        CollectionProfile,
        Notes
    )
    VALUES
    (
        @@SERVERNAME,
        'Admin',
        'Standard',
        'Initial local monitoring repository instance'
    );

    PRINT 'Inserted local instance into dbo.MonitoredInstances.';
END
ELSE
BEGIN
    PRINT 'Local instance already exists in dbo.MonitoredInstances.';
END
GO

PRINT 'SQLMonitoring repository deployment completed.';
GO
