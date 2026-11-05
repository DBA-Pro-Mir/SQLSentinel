USE SQLMonitoring;
GO

/*=============================================================================
  SQLSentinel - Storage Capacity Snapshot Tables
  Safe to run multiple times.
=============================================================================*/

IF OBJECT_ID(N'dbo.DatabaseCapacitySnapshot', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.DatabaseCapacitySnapshot
    (
        DatabaseCapacitySnapshotId bigint IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_DatabaseCapacitySnapshot PRIMARY KEY,

        InstanceId int NOT NULL,
        CaptureTime datetime2(0) NOT NULL,
        DatabaseName sysname NOT NULL,
        DataSizeGB decimal(19,2) NOT NULL,
        LogSizeGB decimal(19,2) NOT NULL,
        TotalSizeGB decimal(19,2) NOT NULL,

        CreatedAt datetime2(0) NOT NULL
            CONSTRAINT DF_DatabaseCapacitySnapshot_CreatedAt DEFAULT (sysdatetime())
    );

    CREATE INDEX IX_DatabaseCapacitySnapshot_Instance_CaptureTime
    ON dbo.DatabaseCapacitySnapshot(InstanceId, CaptureTime DESC);

    CREATE INDEX IX_DatabaseCapacitySnapshot_Database
    ON dbo.DatabaseCapacitySnapshot(InstanceId, DatabaseName, CaptureTime DESC);

    PRINT 'Created dbo.DatabaseCapacitySnapshot.';
END
ELSE
BEGIN
    PRINT 'dbo.DatabaseCapacitySnapshot already exists.';
END
GO

IF OBJECT_ID(N'dbo.VolumeCapacitySnapshot', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.VolumeCapacitySnapshot
    (
        VolumeCapacitySnapshotId bigint IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_VolumeCapacitySnapshot PRIMARY KEY,

        InstanceId int NOT NULL,
        CaptureTime datetime2(0) NOT NULL,
        VolumeName nvarchar(260) NOT NULL,
        TotalGB decimal(19,2) NOT NULL,
        UsedGB decimal(19,2) NOT NULL,
        FreeGB decimal(19,2) NOT NULL,
        FreePercent decimal(9,2) NOT NULL,

        CreatedAt datetime2(0) NOT NULL
            CONSTRAINT DF_VolumeCapacitySnapshot_CreatedAt DEFAULT (sysdatetime())
    );

    CREATE INDEX IX_VolumeCapacitySnapshot_Instance_CaptureTime
    ON dbo.VolumeCapacitySnapshot(InstanceId, CaptureTime DESC);

    CREATE INDEX IX_VolumeCapacitySnapshot_Volume
    ON dbo.VolumeCapacitySnapshot(InstanceId, VolumeName, CaptureTime DESC);

    PRINT 'Created dbo.VolumeCapacitySnapshot.';
END
ELSE
BEGIN
    PRINT 'dbo.VolumeCapacitySnapshot already exists.';
END
GO
