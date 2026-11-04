<#
===============================================================================
 SQLSentinel - Deadlock Collector
 Purpose:
   Reads xml_deadlock_report events from the built-in system_health
   Extended Events session and stores parsed details + full deadlock XML
   in SQLMonitoring.dbo.MetricTextSnapshot.
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

$CollectorName = "Collect-Deadlocks"

function Write-Info { param([string]$Message) Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-Warn { param([string]$Message) Write-Host "[WARN] $Message" -ForegroundColor Yellow }
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

    if (-not (Get-Module -ListAvailable -Name dbatools)) {
        throw "dbatools module is not installed."
    }

    Import-Module dbatools

    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

    $CentralSqlInstance = $config.CentralSqlInstance
    $CentralDatabase = $config.CentralDatabase

    $QueryTimeout = 30
    $LookbackHours = 24
    $MaximumDeadlocks = 100

    if ($null -ne $config.Collectors -and
        $config.Collectors.PSObject.Properties.Name -contains "Deadlocks") {

        $deadlockConfig = $config.Collectors.Deadlocks

        if ($deadlockConfig.PSObject.Properties.Name -contains "QueryTimeoutSeconds") {
            $QueryTimeout = [int]$deadlockConfig.QueryTimeoutSeconds
        }

        if ($deadlockConfig.PSObject.Properties.Name -contains "LookbackHours") {
            $LookbackHours = [int]$deadlockConfig.LookbackHours
        }

        if ($deadlockConfig.PSObject.Properties.Name -contains "MaximumDeadlocks") {
            $MaximumDeadlocks = [int]$deadlockConfig.MaximumDeadlocks
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
SELECT InstanceId, InstanceName
FROM dbo.MonitoredInstances
WHERE IsEnabled = 1
ORDER BY InstanceName;
"@ `
        -QueryTimeout 30

    foreach ($instance in $instances) {

        $InstanceId = [int]$instance.InstanceId
        $TargetInstance = [string]$instance.InstanceName
        $RowsCollected = 0
        $CollectionRunId = $null

        Write-Info "Collecting deadlocks from $TargetInstance"

        try {
            $CollectionRunId = Start-CollectionRun `
                -CentralSqlInstance $CentralSqlInstance `
                -CentralDatabase $CentralDatabase `
                -SqlCredential $SqlCredential `
                -InstanceId $InstanceId `
                -CollectorName $CollectorName

            $deadlockQuery = @"
DECLARE @LookbackStartUtc datetime2(0) = DATEADD(HOUR, -$LookbackHours, SYSUTCDATETIME());
DECLARE @FileName nvarchar(4000);

SELECT @FileName =
    CAST(t.target_data AS xml).value(
        '(EventFileTarget/File/@name)[1]',
        'nvarchar(4000)'
    )
FROM sys.dm_xe_sessions AS s
INNER JOIN sys.dm_xe_session_targets AS t
    ON s.address = t.event_session_address
WHERE s.name = N'system_health'
  AND t.target_name = N'event_file';

IF @FileName IS NULL
BEGIN
    THROW 50001, 'system_health event_file target was not found.', 1;
END;

DECLARE @Wildcard nvarchar(4000) =
    LEFT(@FileName, LEN(@FileName) - CHARINDEX('\', REVERSE(@FileName)) + 1)
    + N'system_health*.xel';

;WITH DeadlockEvents AS
(
    SELECT TOP ($MaximumDeadlocks)
        EventXml = TRY_CONVERT(xml, event_data)
    FROM sys.fn_xe_file_target_read_file(@Wildcard, NULL, NULL, NULL)
    WHERE object_name = N'xml_deadlock_report'
      AND TRY_CONVERT(datetime2(0),
            TRY_CONVERT(xml, event_data).value(
                '(/event/@timestamp)[1]',
                'nvarchar(40)'
            ),
            127
          ) >= @LookbackStartUtc
    ORDER BY
        TRY_CONVERT(datetime2(0),
            TRY_CONVERT(xml, event_data).value(
                '(/event/@timestamp)[1]',
                'nvarchar(40)'
            ),
            127
        ) DESC
),
Parsed AS
(
    SELECT
        EventTimestampUtc =
            TRY_CONVERT(datetime2(0),
                EventXml.value('(/event/@timestamp)[1]', 'nvarchar(40)'),
                127
            ),
        DeadlockXml = EventXml.query('(/event/data/value/deadlock)[1]')
    FROM DeadlockEvents
    WHERE EventXml IS NOT NULL
),
Victim AS
(
    SELECT
        p.EventTimestampUtc,
        p.DeadlockXml,
        VictimProcessId =
            p.DeadlockXml.value('(/deadlock/victim-list/victimProcess/@id)[1]', 'nvarchar(100)')
    FROM Parsed AS p
),
DeadlockData AS
(
    SELECT
        EventTimestamp =
            DATEADD(
                MINUTE,
                DATEDIFF(MINUTE, SYSUTCDATETIME(), SYSDATETIME()),
                v.EventTimestampUtc
            ),
        v.DeadlockXml,

        VictimSpid =
            v.DeadlockXml.value(
                '(/deadlock/process-list/process[@id=sql:column("v.VictimProcessId")]/@spid)[1]',
                'int'
            ),
        VictimDatabaseId =
            v.DeadlockXml.value(
                '(/deadlock/process-list/process[@id=sql:column("v.VictimProcessId")]/@currentdb)[1]',
                'int'
            ),
        VictimLogin =
            v.DeadlockXml.value(
                '(/deadlock/process-list/process[@id=sql:column("v.VictimProcessId")]/@loginname)[1]',
                'nvarchar(256)'
            ),
        VictimHost =
            v.DeadlockXml.value(
                '(/deadlock/process-list/process[@id=sql:column("v.VictimProcessId")]/@hostname)[1]',
                'nvarchar(256)'
            ),
        VictimApplication =
            v.DeadlockXml.value(
                '(/deadlock/process-list/process[@id=sql:column("v.VictimProcessId")]/@clientapp)[1]',
                'nvarchar(512)'
            ),
        VictimTransaction =
            v.DeadlockXml.value(
                '(/deadlock/process-list/process[@id=sql:column("v.VictimProcessId")]/@transactionname)[1]',
                'nvarchar(256)'
            ),
        VictimWaitResource =
            v.DeadlockXml.value(
                '(/deadlock/process-list/process[@id=sql:column("v.VictimProcessId")]/@waitresource)[1]',
                'nvarchar(512)'
            ),
        VictimLockMode =
            v.DeadlockXml.value(
                '(/deadlock/process-list/process[@id=sql:column("v.VictimProcessId")]/@lockMode)[1]',
                'nvarchar(50)'
            ),
        VictimSqlText =
            LTRIM(RTRIM(v.DeadlockXml.value(
                '(/deadlock/process-list/process[@id=sql:column("v.VictimProcessId")]/inputbuf/text())[1]',
                'nvarchar(4000)'
            ))),

        OtherSpid =
            v.DeadlockXml.value(
                '(/deadlock/process-list/process[@id != sql:column("v.VictimProcessId")][1]/@spid)[1]',
                'int'
            ),
        OtherLogin =
            v.DeadlockXml.value(
                '(/deadlock/process-list/process[@id != sql:column("v.VictimProcessId")][1]/@loginname)[1]',
                'nvarchar(256)'
            ),
        OtherHost =
            v.DeadlockXml.value(
                '(/deadlock/process-list/process[@id != sql:column("v.VictimProcessId")][1]/@hostname)[1]',
                'nvarchar(256)'
            ),
        OtherApplication =
            v.DeadlockXml.value(
                '(/deadlock/process-list/process[@id != sql:column("v.VictimProcessId")][1]/@clientapp)[1]',
                'nvarchar(512)'
            ),
        OtherTransaction =
            v.DeadlockXml.value(
                '(/deadlock/process-list/process[@id != sql:column("v.VictimProcessId")][1]/@transactionname)[1]',
                'nvarchar(256)'
            ),
        OtherWaitResource =
            v.DeadlockXml.value(
                '(/deadlock/process-list/process[@id != sql:column("v.VictimProcessId")][1]/@waitresource)[1]',
                'nvarchar(512)'
            ),
        OtherLockMode =
            v.DeadlockXml.value(
                '(/deadlock/process-list/process[@id != sql:column("v.VictimProcessId")][1]/@lockMode)[1]',
                'nvarchar(50)'
            ),
        OtherSqlText =
            LTRIM(RTRIM(v.DeadlockXml.value(
                '(/deadlock/process-list/process[@id != sql:column("v.VictimProcessId")][1]/inputbuf/text())[1]',
                'nvarchar(4000)'
            ))),

        ResourceType =
            v.DeadlockXml.value(
                'local-name((/deadlock/resource-list/*)[1])',
                'nvarchar(128)'
            ),
        ResourceDatabaseId =
            TRY_CONVERT(int, NULLIF(v.DeadlockXml.value(
                '(/deadlock/resource-list/*[1]/@dbid)[1]',
                'nvarchar(20)'
            ), N'')),
        ResourceObject =
            v.DeadlockXml.value(
                '(/deadlock/resource-list/*[1]/@objectname)[1]',
                'nvarchar(512)'
            ),
        ResourceIndex =
            v.DeadlockXml.value(
                '(/deadlock/resource-list/*[1]/@indexname)[1]',
                'nvarchar(512)'
            )
    FROM Victim AS v
)
SELECT
    EventTimestamp,
    DatabaseName = COALESCE(DB_NAME(NULLIF(VictimDatabaseId, 0)), DB_NAME(NULLIF(ResourceDatabaseId, 0))),
    VictimSpid,
    VictimLogin,
    VictimHost,
    VictimApplication,
    VictimTransaction,
    VictimWaitResource,
    VictimLockMode,
    VictimSqlText,
    OtherSpid,
    OtherLogin,
    OtherHost,
    OtherApplication,
    OtherTransaction,
    OtherWaitResource,
    OtherLockMode,
    OtherSqlText,
    ResourceType,
    ResourceObject,
    ResourceIndex,
    DeadlockXml
FROM DeadlockData
ORDER BY EventTimestamp DESC;
"@

            $deadlocks = Invoke-DbaQuery `
                -SqlInstance $TargetInstance `
                -SqlCredential $SqlCredential `
                -Database master `
                -Query $deadlockQuery `
                -QueryTimeout $QueryTimeout `
                -EnableException

            foreach ($deadlock in $deadlocks) {

                if ($null -eq $deadlock.EventTimestamp -or
                    [System.DBNull]::Value.Equals($deadlock.EventTimestamp)) {
                    continue
                }

                $eventTime = ([datetime]$deadlock.EventTimestamp).ToString("yyyy-MM-dd HH:mm:ss")
                $databaseName = if ([string]::IsNullOrWhiteSpace([string]$deadlock.DatabaseName)) { "(unknown)" } else { [string]$deadlock.DatabaseName }

                $victimLogin = if ([string]::IsNullOrWhiteSpace([string]$deadlock.VictimLogin)) { "(unknown)" } else { [string]$deadlock.VictimLogin }
                $victimHost = if ([string]::IsNullOrWhiteSpace([string]$deadlock.VictimHost)) { "(unknown)" } else { [string]$deadlock.VictimHost }
                $victimApp = if ([string]::IsNullOrWhiteSpace([string]$deadlock.VictimApplication)) { "(unknown)" } else { [string]$deadlock.VictimApplication }
                $victimTran = if ([string]::IsNullOrWhiteSpace([string]$deadlock.VictimTransaction)) { "(unknown)" } else { [string]$deadlock.VictimTransaction }
                $victimWait = if ([string]::IsNullOrWhiteSpace([string]$deadlock.VictimWaitResource)) { "(unknown)" } else { [string]$deadlock.VictimWaitResource }
                $victimLock = if ([string]::IsNullOrWhiteSpace([string]$deadlock.VictimLockMode)) { "(unknown)" } else { [string]$deadlock.VictimLockMode }
                $victimSql = if ([string]::IsNullOrWhiteSpace([string]$deadlock.VictimSqlText)) { "(unavailable)" } else { [string]$deadlock.VictimSqlText }

                $otherLogin = if ([string]::IsNullOrWhiteSpace([string]$deadlock.OtherLogin)) { "(unknown)" } else { [string]$deadlock.OtherLogin }
                $otherHost = if ([string]::IsNullOrWhiteSpace([string]$deadlock.OtherHost)) { "(unknown)" } else { [string]$deadlock.OtherHost }
                $otherApp = if ([string]::IsNullOrWhiteSpace([string]$deadlock.OtherApplication)) { "(unknown)" } else { [string]$deadlock.OtherApplication }
                $otherTran = if ([string]::IsNullOrWhiteSpace([string]$deadlock.OtherTransaction)) { "(unknown)" } else { [string]$deadlock.OtherTransaction }
                $otherWait = if ([string]::IsNullOrWhiteSpace([string]$deadlock.OtherWaitResource)) { "(unknown)" } else { [string]$deadlock.OtherWaitResource }
                $otherLock = if ([string]::IsNullOrWhiteSpace([string]$deadlock.OtherLockMode)) { "(unknown)" } else { [string]$deadlock.OtherLockMode }
                $otherSql = if ([string]::IsNullOrWhiteSpace([string]$deadlock.OtherSqlText)) { "(unavailable)" } else { [string]$deadlock.OtherSqlText }

                $resourceType = if ([string]::IsNullOrWhiteSpace([string]$deadlock.ResourceType)) { "(unknown)" } else { [string]$deadlock.ResourceType }
                $resourceObject = if ([string]::IsNullOrWhiteSpace([string]$deadlock.ResourceObject)) { "(unknown)" } else { [string]$deadlock.ResourceObject }
                $resourceIndex = if ([string]::IsNullOrWhiteSpace([string]$deadlock.ResourceIndex)) { "(unknown)" } else { [string]$deadlock.ResourceIndex }

                $detailText = @"
DatabaseName: $databaseName
VictimSpid: $($deadlock.VictimSpid)
VictimLogin: $victimLogin
VictimHost: $victimHost
VictimApplication: $victimApp
VictimTransaction: $victimTran
VictimWaitResource: $victimWait
VictimLockMode: $victimLock
VictimSqlText: $victimSql
OtherSpid: $($deadlock.OtherSpid)
OtherLogin: $otherLogin
OtherHost: $otherHost
OtherApplication: $otherApp
OtherTransaction: $otherTran
OtherWaitResource: $otherWait
OtherLockMode: $otherLock
OtherSqlText: $otherSql
ResourceType: $resourceType
ResourceObject: $resourceObject
ResourceIndex: $resourceIndex
"@

                $safeDetails = $detailText.Replace("'", "''")
                $safeDatabase = $databaseName.Replace("'", "''")

                $deadlockXml = [string]$deadlock.DeadlockXml
                $safeXml = $deadlockXml.Replace("'", "''")

                $inserted = Invoke-DbaQuery `
                    -SqlInstance $CentralSqlInstance `
                    -SqlCredential $SqlCredential `
                    -Database $CentralDatabase `
                    -Query @"
IF NOT EXISTS
(
    SELECT 1
    FROM dbo.MetricTextSnapshot
    WHERE InstanceId = $InstanceId
      AND CaptureTime = '$eventTime'
      AND MetricCategory = N'Deadlock'
      AND DetailType = N'DeadlockDetail'
      AND SourceCollector = N'$CollectorName'
)
BEGIN
    INSERT INTO dbo.MetricTextSnapshot
    (
        InstanceId,
        CaptureTime,
        DatabaseName,
        MetricCategory,
        DetailType,
        Severity,
        NumericValue1,
        NumericValue2,
        Details,
        XmlDetails,
        SourceCollector
    )
    VALUES
    (
        $InstanceId,
        '$eventTime',
        N'$safeDatabase',
        N'Deadlock',
        N'DeadlockDetail',
        N'Critical',
        $([decimal]$deadlock.VictimSpid),
        $([decimal]$deadlock.OtherSpid),
        N'$safeDetails',
        TRY_CONVERT(xml, N'$safeXml'),
        N'$CollectorName'
    );

    SELECT Inserted = 1;
END
ELSE
BEGIN
    SELECT Inserted = 0;
END;
"@ `
                    -As SingleValue `
                    -QueryTimeout 30

                if ([int]$inserted -eq 1) {
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

            Write-Info "Completed $TargetInstance ($RowsCollected new deadlocks)"
        }
        catch {
            $err = $_.Exception.Message
            Write-Warn ("Failed for {0}: {1}" -f $TargetInstance, $err)

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
