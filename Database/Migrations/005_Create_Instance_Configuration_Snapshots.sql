USE [SQLMonitoring];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID(N'dbo.InstanceVersionSnapshot', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.InstanceVersionSnapshot
    (
        InstanceVersionSnapshotId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_InstanceVersionSnapshot PRIMARY KEY,
        InstanceId int NOT NULL,
        CaptureTime datetime2(0) NOT NULL,
        ProductVersion nvarchar(50) NULL,
        ProductLevel nvarchar(50) NULL,
        Edition nvarchar(200) NULL,
        ProductUpdateLevel nvarchar(50) NULL,
        ProductUpdateReference nvarchar(100) NULL,
        GlobalTraceFlags nvarchar(2000) NULL,
        CreatedAt datetime2(0) NOT NULL CONSTRAINT DF_InstanceVersionSnapshot_CreatedAt DEFAULT (SYSDATETIME())
    );

    CREATE INDEX IX_InstanceVersionSnapshot_Instance_CaptureTime
        ON dbo.InstanceVersionSnapshot (InstanceId, CaptureTime DESC);
END;
GO

IF OBJECT_ID(N'dbo.InstanceConfigurationSnapshot', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.InstanceConfigurationSnapshot
    (
        InstanceConfigurationSnapshotId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_InstanceConfigurationSnapshot PRIMARY KEY,
        InstanceId int NOT NULL,
        CaptureTime datetime2(0) NOT NULL,
        SettingName sysname NOT NULL,
        Description nvarchar(500) NULL,
        CurrentValue bigint NULL,
        ExpectedValue bigint NULL,
        ComplianceStatus varchar(10) NOT NULL,
        CreatedAt datetime2(0) NOT NULL CONSTRAINT DF_InstanceConfigurationSnapshot_CreatedAt DEFAULT (SYSDATETIME())
    );

    CREATE INDEX IX_InstanceConfigurationSnapshot_Instance_CaptureTime
        ON dbo.InstanceConfigurationSnapshot (InstanceId, CaptureTime DESC);

    CREATE INDEX IX_InstanceConfigurationSnapshot_Setting
        ON dbo.InstanceConfigurationSnapshot (SettingName, CaptureTime DESC);
END;
GO