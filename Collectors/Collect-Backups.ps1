<#
===============================================================================
 SQLSentinel - Backup Status Collector
===============================================================================
#>

[CmdletBinding()]
param
(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = ".\Config\SQLSentinel.config.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$CollectorName = "Collect-Backups"

function Write-Info { param([string]$Message) Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-Fail { param([string]$Message) Write-Host "[ERROR] $Message" -ForegroundColor Red }

function Start-CollectionRun {
    param(
        [string]$CentralSqlInstance,
        [string]$CentralDatabase,
        [pscredential]$SqlCredential,
        [int]$InstanceId,
        [string]$CollectorName
    )

    Invoke-DbaQuery `
        -SqlInstance $CentralSqlInstance `
        -SqlCredential $SqlCredential `
        -Database $CentralDatabase `
        -Query @"
INSERT INTO dbo.CollectionRunHistory
(
    CollectorName,
    InstanceId,
    StartedAt,
    Status
)
OUTPUT inserted.CollectionRunId
VALUES
(
    '$CollectorName',
    $InstanceId,
    SYSDATETIME(),
    'Running'
);
"@ `
        -As SingleValue
}

function Complete-CollectionRun {
    param(
        [string]$CentralSqlInstance,
        [string]$CentralDatabase,
        [pscredential]$SqlCredential,
        [bigint]$CollectionRunId,
        [string]$Status,
        [int]$RowsCollected,
        [string]$ErrorMessage = $null
    )

    $safeError = if ($null -eq $ErrorMessage) { "NULL" } else { "N'" + $ErrorMessage.Replace("'", "''") + "'" }

    Invoke-DbaQuery `
        -SqlInstance $CentralSqlInstance `
        -SqlCredential $SqlCredential `
        -Database $CentralDatabase `
        -Query @"
UPDATE dbo.CollectionRunHistory
SET
    FinishedAt = SYSDATETIME(),
    Status = '$Status',
    RowsCollected = $RowsCollected,
    DurationMs = DATEDIFF(MILLISECOND, StartedAt, SYSDATETIME()),
    ErrorMessage = $safeError
WHERE CollectionRunId = $CollectionRunId;
"@ | Out-Null
}

try {
    if (-not (Test-Path $ConfigPath)) {
        throw "Config file not found: $ConfigPath"
    }

    Import-Module dbatools

    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

    $CentralSqlInstance = $config.CentralSqlInstance
    $CentralDatabase = $config.CentralDatabase

    $QueryTimeout = 120
    $FullBackupWarningHours = 24
    $DiffBackupWarningHours = 24
    $LogBackupWarningHours = 2
    $MaximumDetailRows = 200

    if ($null -ne $config.Collectors -and
        $config.Collectors.PSObject.Properties.Name -contains "Backups") {

        $backupConfig = $config.Collectors.Backups

        if ($backupConfig.PSObject.Properties.Name -contains "QueryTimeoutSeconds") {
            $QueryTimeout = [int]$backupConfig.QueryTimeoutSeconds
        }

        if ($backupConfig.PSObject.Properties.Name -contains "FullBackupWarningHours") {
            $FullBackupWarningHours = [int]$backupConfig.FullBackupWarningHours
        }

        if ($backupConfig.PSObject.Properties.Name -contains "DiffBackupWarningHours") {
            $DiffBackupWarningHours = [int]$backupConfig.DiffBackupWarningHours
        }

        if ($backupConfig.PSObject.Properties.Name -contains "LogBackupWarningHours") {
            $LogBackupWarningHours = [int]$backupConfig.LogBackupWarningHours
        }

        if ($backupConfig.PSObject.Properties.Name -contains "MaximumDetailRows") {
            $MaximumDetailRows = [int]$backupConfig.MaximumDetailRows
        }
    }

    $SqlCredential = $null

    if ($config.SqlCredential.Username -and $config.SqlCredential.Password) {
        $SqlCredential = New-Object System.Management.Automation.PSCredential(
            $config.SqlCredential.Username,
            (ConvertTo-SecureString $config.SqlCredential.Password -AsPlainText -Force)
        )
    }

    Write-Info "Starting $CollectorName"
    Write-Info "Repository: $CentralSqlInstance / $CentralDatabase"

    $instances = Invoke-DbaQuery `
        -SqlInstance $CentralSqlInstance `
        -SqlCredential $SqlCredential `
        -Database $CentralDatabase `
        -Query @"
SELECT
    InstanceId,
    InstanceName,
    ComplianceProfile = ISNULL(ComplianceProfile, 'V1_SIMPLE')
FROM dbo.MonitoredInstances
WHERE IsEnabled = 1
ORDER BY InstanceName;
"@ `
        -QueryTimeout 30 `
        -EnableException

    foreach ($instance in $instances) {

        $InstanceId = [int]$instance.InstanceId
        $TargetInstance = [string]$instance.InstanceName
        $ComplianceProfile = if ([string]::IsNullOrWhiteSpace([string]$instance.ComplianceProfile)) { "V1_SIMPLE" } else { [string]$instance.ComplianceProfile }
        $RowsCollected = 0
        $CollectionRunId = $null

        Write-Info "Collecting backup compliance from $TargetInstance using profile $ComplianceProfile"

        try {
            $CollectionRunId = Start-CollectionRun `
                -CentralSqlInstance $CentralSqlInstance `
                -CentralDatabase $CentralDatabase `
                -SqlCredential $SqlCredential `
                -InstanceId $InstanceId `
                -CollectorName $CollectorName

            $safeComplianceProfile = $ComplianceProfile.Replace("'", "''")

            $backupQuery = @"
DECLARE @ComplianceProfile varchar(20) = '$safeComplianceProfile';
DECLARE @ExpectedRecoveryModel varchar(20) =
    CASE
        WHEN @ComplianceProfile = 'V2_FULL' THEN 'FULL'
        ELSE 'SIMPLE'
    END;
DECLARE @RequiresLogBackups bit =
    CASE
        WHEN @ComplianceProfile = 'V2_FULL' THEN 1
        ELSE 0
    END;

IF OBJECT_ID('tempdb..#BackupStatus') IS NOT NULL
    DROP TABLE #BackupStatus;

WITH LastBackups AS
(
    SELECT
        bs.database_name,
        bs.type,
        bs.backup_finish_date,
        BackupSizeMB = CAST(bs.backup_size / 1024.0 / 1024.0 AS decimal(19,2)),
        CompressedBackupSizeMB = CAST(bs.compressed_backup_size / 1024.0 / 1024.0 AS decimal(19,2)),
        DurationSeconds = DATEDIFF(SECOND, bs.backup_start_date, bs.backup_finish_date),
        PhysicalDeviceName = bmf.physical_device_name,
        rn = ROW_NUMBER() OVER
        (
            PARTITION BY bs.database_name, bs.type
            ORDER BY bs.backup_finish_date DESC
        )
    FROM msdb.dbo.backupset bs
    LEFT JOIN msdb.dbo.backupmediafamily bmf
        ON bs.media_set_id = bmf.media_set_id
    WHERE bs.type IN ('D','I','L')
)
SELECT
    d.name AS DatabaseName,
    d.recovery_model_desc,
    d.state_desc,
    ComplianceProfile = @ComplianceProfile,
    ExpectedRecoveryModel = @ExpectedRecoveryModel,
    RequiresLogBackups = @RequiresLogBackups,
    LastFullBackupTime = MAX(CASE WHEN lb.type = 'D' AND lb.rn = 1 THEN lb.backup_finish_date END),
    LastDiffBackupTime = MAX(CASE WHEN lb.type = 'I' AND lb.rn = 1 THEN lb.backup_finish_date END),
    LastLogBackupTime = MAX(CASE WHEN lb.type = 'L' AND lb.rn = 1 THEN lb.backup_finish_date END),
    LastFullBackupAgeHours =
        DATEDIFF(HOUR, MAX(CASE WHEN lb.type = 'D' AND lb.rn = 1 THEN lb.backup_finish_date END), SYSDATETIME()),
    LastDiffBackupAgeHours =
        DATEDIFF(HOUR, MAX(CASE WHEN lb.type = 'I' AND lb.rn = 1 THEN lb.backup_finish_date END), SYSDATETIME()),
    LastLogBackupAgeHours =
        DATEDIFF(HOUR, MAX(CASE WHEN lb.type = 'L' AND lb.rn = 1 THEN lb.backup_finish_date END), SYSDATETIME()),
    LastFullBackupSizeMB = ISNULL(MAX(CASE WHEN lb.type = 'D' AND lb.rn = 1 THEN lb.BackupSizeMB END), 0),
    LastDiffBackupSizeMB = ISNULL(MAX(CASE WHEN lb.type = 'I' AND lb.rn = 1 THEN lb.BackupSizeMB END), 0),
    LastLogBackupSizeMB = ISNULL(MAX(CASE WHEN lb.type = 'L' AND lb.rn = 1 THEN lb.BackupSizeMB END), 0),
    LastFullBackupDurationSeconds = ISNULL(MAX(CASE WHEN lb.type = 'D' AND lb.rn = 1 THEN lb.DurationSeconds END), 0),
    LastDiffBackupDurationSeconds = ISNULL(MAX(CASE WHEN lb.type = 'I' AND lb.rn = 1 THEN lb.DurationSeconds END), 0),
    LastLogBackupDurationSeconds = ISNULL(MAX(CASE WHEN lb.type = 'L' AND lb.rn = 1 THEN lb.DurationSeconds END), 0),
    LastFullBackupDevice = MAX(CASE WHEN lb.type = 'D' AND lb.rn = 1 THEN lb.PhysicalDeviceName END),
    LastDiffBackupDevice = MAX(CASE WHEN lb.type = 'I' AND lb.rn = 1 THEN lb.PhysicalDeviceName END),
    LastLogBackupDevice = MAX(CASE WHEN lb.type = 'L' AND lb.rn = 1 THEN lb.PhysicalDeviceName END)
INTO #BackupStatus
FROM sys.databases d
LEFT JOIN LastBackups lb
    ON d.name = lb.database_name
WHERE d.name <> 'tempdb'
  AND d.state_desc = 'ONLINE'
GROUP BY
    d.name,
    d.recovery_model_desc,
    d.state_desc;

SELECT
    DatabaseCount = COUNT_BIG(1),
    DatabasesWithoutFullBackup =
        ISNULL(SUM(CASE WHEN LastFullBackupTime IS NULL THEN 1 ELSE 0 END), 0),
    DatabasesWithOldFullBackup =
        ISNULL(SUM(CASE WHEN LastFullBackupAgeHours > $FullBackupWarningHours THEN 1 ELSE 0 END), 0),
    DatabasesWithOldDiffBackup =
        ISNULL(SUM(CASE WHEN LastDiffBackupAgeHours > $DiffBackupWarningHours THEN 1 ELSE 0 END), 0),
    RecoveryModelViolations =
        ISNULL(SUM(CASE WHEN recovery_model_desc COLLATE DATABASE_DEFAULT <> ExpectedRecoveryModel COLLATE DATABASE_DEFAULT THEN 1 ELSE 0 END), 0),
    DatabasesWithoutRequiredLogBackup =
        ISNULL(SUM(CASE WHEN RequiresLogBackups = 1 AND recovery_model_desc IN ('FULL','BULK_LOGGED') AND LastLogBackupTime IS NULL THEN 1 ELSE 0 END), 0),
    DatabasesWithOldRequiredLogBackup =
        ISNULL(SUM(CASE WHEN RequiresLogBackups = 1 AND recovery_model_desc IN ('FULL','BULK_LOGGED') AND LastLogBackupAgeHours > $LogBackupWarningHours THEN 1 ELSE 0 END), 0),
    NonCompliantDatabaseCount =
        ISNULL(SUM(CASE
            WHEN recovery_model_desc COLLATE DATABASE_DEFAULT <> ExpectedRecoveryModel COLLATE DATABASE_DEFAULT THEN 1
            WHEN LastFullBackupTime IS NULL THEN 1
            WHEN LastFullBackupAgeHours > $FullBackupWarningHours THEN 1
            WHEN RequiresLogBackups = 1 AND recovery_model_desc IN ('FULL','BULK_LOGGED') AND LastLogBackupTime IS NULL THEN 1
            WHEN RequiresLogBackups = 1 AND recovery_model_desc IN ('FULL','BULK_LOGGED') AND LastLogBackupAgeHours > $LogBackupWarningHours THEN 1
            ELSE 0
        END), 0),
    MaxFullBackupAgeHours =
        ISNULL(MAX(ISNULL(LastFullBackupAgeHours, 0)), 0),
    MaxLogBackupAgeHours =
        ISNULL(MAX(ISNULL(LastLogBackupAgeHours, 0)), 0)
FROM #BackupStatus;

SELECT TOP ($MaximumDetailRows)
    DatabaseName,
    recovery_model_desc,
    ComplianceProfile,
    ExpectedRecoveryModel,
    RequiresLogBackups,
    LastFullBackupTime,
    LastDiffBackupTime,
    LastLogBackupTime,
    LastFullBackupAgeHours,
    LastDiffBackupAgeHours,
    LastLogBackupAgeHours,
    LastFullBackupSizeMB,
    LastDiffBackupSizeMB,
    LastLogBackupSizeMB,
    LastFullBackupDurationSeconds,
    LastDiffBackupDurationSeconds,
    LastLogBackupDurationSeconds,
    LastFullBackupDevice,
    LastDiffBackupDevice,
    LastLogBackupDevice,
    IssueType =
        CASE
            WHEN recovery_model_desc COLLATE DATABASE_DEFAULT <> ExpectedRecoveryModel COLLATE DATABASE_DEFAULT THEN 'RecoveryModelMismatch'
            WHEN LastFullBackupTime IS NULL THEN 'MissingFullBackup'
            WHEN LastFullBackupAgeHours > $FullBackupWarningHours THEN 'OldFullBackup'
            WHEN RequiresLogBackups = 1 AND recovery_model_desc IN ('FULL','BULK_LOGGED') AND LastLogBackupTime IS NULL THEN 'MissingLogBackup'
            WHEN RequiresLogBackups = 1 AND recovery_model_desc IN ('FULL','BULK_LOGGED') AND LastLogBackupAgeHours > $LogBackupWarningHours THEN 'OldLogBackup'
            ELSE 'OK'
        END,
    Severity =
        CASE
            WHEN recovery_model_desc COLLATE DATABASE_DEFAULT <> ExpectedRecoveryModel COLLATE DATABASE_DEFAULT THEN 'Critical'
            WHEN LastFullBackupTime IS NULL THEN 'Critical'
            WHEN LastFullBackupAgeHours > $FullBackupWarningHours THEN 'Warning'
            WHEN RequiresLogBackups = 1 AND recovery_model_desc IN ('FULL','BULK_LOGGED') AND LastLogBackupTime IS NULL THEN 'Critical'
            WHEN RequiresLogBackups = 1 AND recovery_model_desc IN ('FULL','BULK_LOGGED') AND LastLogBackupAgeHours > $LogBackupWarningHours THEN 'Critical'
            ELSE 'Info'
        END
FROM #BackupStatus
WHERE
    recovery_model_desc COLLATE DATABASE_DEFAULT <> ExpectedRecoveryModel COLLATE DATABASE_DEFAULT
    OR LastFullBackupTime IS NULL
    OR LastFullBackupAgeHours > $FullBackupWarningHours
    OR (RequiresLogBackups = 1 AND recovery_model_desc IN ('FULL','BULK_LOGGED') AND LastLogBackupTime IS NULL)
    OR (RequiresLogBackups = 1 AND recovery_model_desc IN ('FULL','BULK_LOGGED') AND LastLogBackupAgeHours > $LogBackupWarningHours)
ORDER BY
    CASE
        WHEN recovery_model_desc COLLATE DATABASE_DEFAULT <> ExpectedRecoveryModel COLLATE DATABASE_DEFAULT THEN 1
        WHEN LastFullBackupTime IS NULL THEN 2
        WHEN RequiresLogBackups = 1 AND recovery_model_desc IN ('FULL','BULK_LOGGED') AND LastLogBackupTime IS NULL THEN 3
        WHEN RequiresLogBackups = 1 AND recovery_model_desc IN ('FULL','BULK_LOGGED') AND LastLogBackupAgeHours > $LogBackupWarningHours THEN 4
        WHEN LastFullBackupAgeHours > $FullBackupWarningHours THEN 5
        ELSE 99
    END,
    DatabaseName;

DROP TABLE #BackupStatus;
"@

            try {
                $results = Invoke-DbaQuery `
                    -SqlInstance $TargetInstance `
                    -SqlCredential $SqlCredential `
                    -Database master `
                    -Query $backupQuery `
                    -As DataSet `
                    -QueryTimeout $QueryTimeout `
                    -EnableException
            }
            catch {
                throw "Invoke-DbaQuery failed on $TargetInstance while collecting backup compliance: $($_.Exception.Message)"
            }

            if ($null -eq $results -or $results -isnot [System.Data.DataSet] -or $results.Tables.Count -eq 0 -or $results.Tables[0].Rows.Count -eq 0) {
                throw "Backup compliance query did not return a valid DataSet for $TargetInstance."
            }

            $captureTime = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

            $summary = $results.Tables[0].Rows[0]

            $summaryMetrics = @(
                @{ Name = "DatabaseCount"; Value = [decimal]$summary.DatabaseCount; Unit = "count" },
                @{ Name = "DatabasesWithoutFullBackup"; Value = [decimal]$summary.DatabasesWithoutFullBackup; Unit = "count" },
                @{ Name = "DatabasesWithOldFullBackup"; Value = [decimal]$summary.DatabasesWithOldFullBackup; Unit = "count" },
                @{ Name = "DatabasesWithOldDiffBackup"; Value = [decimal]$summary.DatabasesWithOldDiffBackup; Unit = "count" },
                @{ Name = "RecoveryModelViolations"; Value = [decimal]$summary.RecoveryModelViolations; Unit = "count" },
                @{ Name = "DatabasesWithoutRequiredLogBackup"; Value = [decimal]$summary.DatabasesWithoutRequiredLogBackup; Unit = "count" },
                @{ Name = "DatabasesWithOldRequiredLogBackup"; Value = [decimal]$summary.DatabasesWithOldRequiredLogBackup; Unit = "count" },
                @{ Name = "NonCompliantDatabaseCount"; Value = [decimal]$summary.NonCompliantDatabaseCount; Unit = "count" },
                @{ Name = "MaxFullBackupAgeHours"; Value = [decimal]$summary.MaxFullBackupAgeHours; Unit = "hours" },
                @{ Name = "MaxLogBackupAgeHours"; Value = [decimal]$summary.MaxLogBackupAgeHours; Unit = "hours" }
            )

            foreach ($metric in $summaryMetrics) {
                Invoke-DbaQuery `
                    -SqlInstance $CentralSqlInstance `
                    -SqlCredential $SqlCredential `
                    -Database $CentralDatabase `
                    -Query @"
INSERT INTO dbo.MetricSnapshot
(
    InstanceId,
    CaptureTime,
    DatabaseName,
    ObjectName,
    CounterName,
    InstanceName,
    MetricCategory,
    MetricValue,
    MetricType,
    Unit,
    SourceCollector
)
VALUES
(
    $InstanceId,
    '$captureTime',
    NULL,
    'BackupComplianceSummary',
    '$($metric.Name)',
    NULL,
    'BackupCompliance',
    $($metric.Value),
    'Gauge',
    '$($metric.Unit)',
    '$CollectorName'
);
"@ `
                    -QueryTimeout $QueryTimeout | Out-Null

                $RowsCollected++
            }

            if ($results.Tables.Count -gt 1) {
                foreach ($issue in $results.Tables[1].Rows) {

                    $dbName = if ([string]::IsNullOrWhiteSpace([string]$issue.DatabaseName)) { "(unknown)" } else { [string]$issue.DatabaseName }
                    $issueType = if ([string]::IsNullOrWhiteSpace([string]$issue.IssueType)) { "Unknown" } else { [string]$issue.IssueType }
                    $severity = if ([string]::IsNullOrWhiteSpace([string]$issue.Severity)) { "Warning" } else { [string]$issue.Severity }

                    $detailText = @"
DatabaseName: $dbName
IssueType: $issueType
Severity: $severity
ComplianceProfile: $($issue.ComplianceProfile)
ExpectedRecoveryModel: $($issue.ExpectedRecoveryModel)
ActualRecoveryModel: $($issue.recovery_model_desc)
RequiresLogBackups: $($issue.RequiresLogBackups)
LastFullBackupTime: $($issue.LastFullBackupTime)
LastDiffBackupTime: $($issue.LastDiffBackupTime)
LastLogBackupTime: $($issue.LastLogBackupTime)
LastFullBackupAgeHours: $($issue.LastFullBackupAgeHours)
LastDiffBackupAgeHours: $($issue.LastDiffBackupAgeHours)
LastLogBackupAgeHours: $($issue.LastLogBackupAgeHours)
LastFullBackupSizeMB: $($issue.LastFullBackupSizeMB)
LastDiffBackupSizeMB: $($issue.LastDiffBackupSizeMB)
LastLogBackupSizeMB: $($issue.LastLogBackupSizeMB)
LastFullBackupDurationSeconds: $($issue.LastFullBackupDurationSeconds)
LastDiffBackupDurationSeconds: $($issue.LastDiffBackupDurationSeconds)
LastLogBackupDurationSeconds: $($issue.LastLogBackupDurationSeconds)
LastFullBackupDevice: $($issue.LastFullBackupDevice)
LastDiffBackupDevice: $($issue.LastDiffBackupDevice)
LastLogBackupDevice: $($issue.LastLogBackupDevice)
"@

                    $safeDetails = $detailText.Replace("'", "''")
                    $safeDbName = $dbName.Replace("'", "''")
                    $safeIssueType = $issueType.Replace("'", "''")
                    $safeSeverity = $severity.Replace("'", "''")
                    $numericValue1 = if ($null -eq $issue.LastFullBackupAgeHours -or [string]::IsNullOrWhiteSpace([string]$issue.LastFullBackupAgeHours)) { 0 } else { [decimal]$issue.LastFullBackupAgeHours }

                    Invoke-DbaQuery `
                        -SqlInstance $CentralSqlInstance `
                        -SqlCredential $SqlCredential `
                        -Database $CentralDatabase `
                        -Query @"
INSERT INTO dbo.MetricTextSnapshot
(
    InstanceId,
    CaptureTime,
    DatabaseName,
    MetricCategory,
    DetailType,
    Severity,
    NumericValue1,
    Details,
    SourceCollector
)
VALUES
(
    $InstanceId,
    '$captureTime',
    N'$safeDbName',
    'BackupCompliance',
    '$safeIssueType',
    '$safeSeverity',
    $numericValue1,
    N'$safeDetails',
    '$CollectorName'
);
"@ `
                        -QueryTimeout $QueryTimeout | Out-Null

                    $RowsCollected++
                }
            }

            Complete-CollectionRun `
                -CentralSqlInstance $CentralSqlInstance `
                -CentralDatabase $CentralDatabase `
                -SqlCredential $SqlCredential `
                -CollectionRunId $CollectionRunId `
                -Status "Success" `
                -RowsCollected $RowsCollected

            Write-Info "Completed $TargetInstance ($RowsCollected rows)"
        }
        catch {
            $err = $_.Exception.Message
            Write-Fail ("Failed for {0}: {1}" -f $TargetInstance, $err)

            if ($null -ne $CollectionRunId) {
                Complete-CollectionRun `
                    -CentralSqlInstance $CentralSqlInstance `
                    -CentralDatabase $CentralDatabase `
                    -SqlCredential $SqlCredential `
                    -CollectionRunId $CollectionRunId `
                    -Status "Failed" `
                    -RowsCollected $RowsCollected `
                    -ErrorMessage $err
            }
        }
    }

    Write-Info "$CollectorName completed"
}
catch {
    Write-Fail "$CollectorName failed: $($_.Exception.Message)"
    throw
}
