/*
===============================================================================
 SQLSentinel - Add ComplianceProfile to MonitoredInstances
===============================================================================
 Purpose:
   Adds an instance-level compliance profile used by database backup/recovery
   compliance collectors.

 Profiles used today:
   V1_SIMPLE - user databases are expected to be SIMPLE recovery; log backups
               are not required.
   V2_FULL   - user databases are expected to be FULL recovery; log backups
               are required and monitored.
===============================================================================
*/

IF COL_LENGTH('dbo.MonitoredInstances', 'ComplianceProfile') IS NULL
BEGIN
    ALTER TABLE dbo.MonitoredInstances
    ADD ComplianceProfile varchar(20) NOT NULL
        CONSTRAINT DF_MonitoredInstances_ComplianceProfile
        DEFAULT ('V1_SIMPLE');
END;
GO

/*
Example: set Version 2 servers after reviewing your inventory.

UPDATE dbo.MonitoredInstances
SET ComplianceProfile = 'V2_FULL'
WHERE InstanceName IN
(
    'SERVER1',
    'SERVER2'
);
*/

SELECT
    InstanceId,
    InstanceName,
    ComplianceProfile
FROM dbo.MonitoredInstances
ORDER BY InstanceName;
GO
