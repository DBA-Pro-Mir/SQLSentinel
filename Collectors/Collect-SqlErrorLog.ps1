[CmdletBinding()]
param([string]$ConfigPath = '.\Config\SQLSentinel.config.json')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$CollectorName = 'Collect-SqlErrorLog'

function Write-Info { param([string]$Message) Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-Warn { param([string]$Message) Write-Host "[WARN] $Message" -ForegroundColor Yellow }

function Escape-SqlText {
    param([object]$Value)
    if ($null -eq $Value -or [System.DBNull]::Value.Equals($Value)) { return '' }
    return ([string]$Value).Replace("'","''")
}

if (-not (Test-Path $ConfigPath)) { throw "Config file not found: $ConfigPath" }

Import-Module dbatools -ErrorAction Stop
Set-DbatoolsConfig -FullName 'sql.connection.trustcert' -Value $true

$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$CentralSqlInstance = [string]$config.CentralSqlInstance
$CentralDatabase = [string]$config.CentralDatabase
$QueryTimeout = 60
$LookbackDays = 30

$SqlCredential = $null
if ($config.SqlCredential.Username -and $config.SqlCredential.Password) {
    $SqlCredential = New-Object System.Management.Automation.PSCredential(
        $config.SqlCredential.Username,
        (ConvertTo-SecureString $config.SqlCredential.Password -AsPlainText -Force)
    )
}

$instances = Invoke-DbaQuery -SqlInstance $CentralSqlInstance -SqlCredential $SqlCredential -Database $CentralDatabase -Query @"
SELECT [InstanceId], [InstanceName]
FROM dbo.MonitoredInstances
WHERE [IsEnabled] = 1
ORDER BY [InstanceName];
"@ -QueryTimeout 30 -EnableException

foreach ($instance in $instances) {
    $InstanceId = [int]$instance.InstanceId
    $TargetInstance = [string]$instance.InstanceName
    $RowsCollected = 0
    $CollectionRunId = $null

    Write-Info "Collecting SQL operational summary from $TargetInstance"

    try {
        $CollectionRunId = Invoke-DbaQuery -SqlInstance $CentralSqlInstance -SqlCredential $SqlCredential -Database $CentralDatabase -As SingleValue -EnableException -Query @"
INSERT INTO dbo.CollectionRunHistory ([CollectorName],[InstanceId],[StartedAt],[Status])
OUTPUT inserted.CollectionRunId
VALUES (N'$CollectorName',$InstanceId,SYSDATETIME(),N'Running');
"@

        $summary = Invoke-DbaQuery -SqlInstance $TargetInstance -SqlCredential $SqlCredential -Database master -Query @"
SET NOCOUNT ON;

DECLARE @Days int = $LookbackDays;
DECLARE @StartDate datetime = DATEADD(DAY, -@Days, GETDATE());
DECLARE @Today datetime = CONVERT(date, GETDATE());

CREATE TABLE #Logs
(
    ArchiveNo int,
    LogDate   datetime,
    LogSize   bigint
);

INSERT INTO #Logs
EXEC master.dbo.sp_enumerrorlogs;

CREATE TABLE #ErrorLog
(
    LogDate     datetime,
    ProcessInfo nvarchar(50),
    [Text]      nvarchar(max)
);

DECLARE @LogNumber int;

DECLARE LogCursor CURSOR LOCAL FAST_FORWARD FOR
SELECT [ArchiveNo]
FROM #Logs
WHERE [LogDate] >= DATEADD(DAY, -1, @StartDate)
   OR [ArchiveNo] = 0;

OPEN LogCursor;
FETCH NEXT FROM LogCursor INTO @LogNumber;

WHILE @@FETCH_STATUS = 0
BEGIN
    INSERT INTO #ErrorLog
    EXEC master.dbo.xp_readerrorlog @LogNumber, 1;

    FETCH NEXT FROM LogCursor INTO @LogNumber;
END;

CLOSE LogCursor;
DEALLOCATE LogCursor;

;WITH Events AS
(
    SELECT
        [LogDate],
        [Text],
        [IsSystemShutdown] =
            CASE WHEN [Text] LIKE N'%terminating because of a system shutdown%' THEN 1 ELSE 0 END,
        [IsServiceStop] =
            CASE WHEN [Text] LIKE N'%terminating in response to a ''stop'' request%' THEN 1 ELSE 0 END
    FROM #ErrorLog
    WHERE [LogDate] >= @StartDate
)
SELECT
    [CaptureTime] = SYSDATETIME(),
    [SeverityEventsToday] =
        (
            SELECT COUNT_BIG(*)
            FROM #ErrorLog
            WHERE [LogDate] >= @Today
              AND [Text] LIKE N'%Severity%'
        ),
    [FailureEventsToday] =
        (
            SELECT COUNT_BIG(*)
            FROM #ErrorLog
            WHERE [LogDate] >= @Today
              AND [Text] LIKE N'%fail%'
        ),
    [SqlServerStartEpochSeconds] =
        DATEDIFF_BIG
        (
            SECOND,
            CONVERT(datetime2(0),'19700101'),
            (SELECT [sqlserver_start_time] FROM sys.dm_os_sys_info)
        ),
    [ShutdownCount30Days] =
        ISNULL(SUM(CASE WHEN [IsSystemShutdown] = 1 OR [IsServiceStop] = 1 THEN 1 ELSE 0 END), 0),
    [SystemShutdownCount30Days] =
        ISNULL(SUM([IsSystemShutdown]), 0),
    [ServiceStopCount30Days] =
        ISNULL(SUM([IsServiceStop]), 0),
    [SqlUptimeHours] =
        CONVERT(decimal(19,2),
            DATEDIFF(MINUTE,
                (SELECT [sqlserver_start_time] FROM sys.dm_os_sys_info),
                SYSDATETIME()
            ) / 60.0
        ),
    [DaysSinceLastRestart] =
        CONVERT(decimal(19,2),
            DATEDIFF(MINUTE,
                (SELECT [sqlserver_start_time] FROM sys.dm_os_sys_info),
                SYSDATETIME()
            ) / 1440.0
        )
FROM Events;

DROP TABLE #ErrorLog;
DROP TABLE #Logs;
"@ -QueryTimeout $QueryTimeout -EnableException | Select-Object -First 1

        if ($null -eq $summary) {
            throw "SQL operational summary returned no rows."
        }

        $captureTime = ([datetime]$summary.CaptureTime).ToString('yyyy-MM-dd HH:mm:ss')
        $currentStartEpoch = [decimal]$summary.SqlServerStartEpochSeconds

        $previousStartEpoch = Invoke-DbaQuery `
            -SqlInstance $CentralSqlInstance `
            -SqlCredential $SqlCredential `
            -Database $CentralDatabase `
            -As SingleValue `
            -EnableException `
            -Query @"
SELECT TOP (1)
    [MetricValue]
FROM dbo.MetricSnapshot
WHERE [InstanceId] = $InstanceId
  AND [SourceCollector] = N'$CollectorName'
  AND [MetricCategory] = N'SqlOperational'
  AND [ObjectName] = N'SqlOperationalSummary'
  AND [CounterName] = N'SqlServerStartEpochSeconds'
ORDER BY [CaptureTime] DESC, [MetricSnapshotId] DESC;
"@

        $restartDetected = 0
        if ($null -ne $previousStartEpoch -and
            -not [System.DBNull]::Value.Equals($previousStartEpoch) -and
            [decimal]$previousStartEpoch -ne $currentStartEpoch) {
            $restartDetected = 1
        }

        $metrics = @(
            @{ Name='SeverityEventsToday'; Value=[decimal]$summary.SeverityEventsToday; Unit='count' },
            @{ Name='FailureEventsToday'; Value=[decimal]$summary.FailureEventsToday; Unit='count' },
            @{ Name='SqlServerStartEpochSeconds'; Value=$currentStartEpoch; Unit='epoch_sec' },
            @{ Name='RestartDetected'; Value=[decimal]$restartDetected; Unit='count' },
            @{ Name='ShutdownCount30Days'; Value=[decimal]$summary.ShutdownCount30Days; Unit='count' },
            @{ Name='SystemShutdownCount30Days'; Value=[decimal]$summary.SystemShutdownCount30Days; Unit='count' },
            @{ Name='ServiceStopCount30Days'; Value=[decimal]$summary.ServiceStopCount30Days; Unit='count' },
            @{ Name='SqlUptimeHours'; Value=[decimal]$summary.SqlUptimeHours; Unit='hours' },
            @{ Name='DaysSinceLastRestart'; Value=[decimal]$summary.DaysSinceLastRestart; Unit='days' }
        )

        foreach ($metric in $metrics) {
            Invoke-DbaQuery -SqlInstance $CentralSqlInstance -SqlCredential $SqlCredential -Database $CentralDatabase -EnableException -Query @"
INSERT INTO dbo.MetricSnapshot
(
    [InstanceId],
    [CaptureTime],
    [DatabaseName],
    [ObjectName],
    [CounterName],
    [InstanceName],
    [MetricCategory],
    [MetricValue],
    [MetricType],
    [Unit],
    [SourceCollector]
)
VALUES
(
    $InstanceId,
    '$captureTime',
    NULL,
    N'SqlOperationalSummary',
    N'$($metric.Name)',
    NULL,
    N'SqlOperational',
    $($metric.Value),
    N'Gauge',
    N'$($metric.Unit)',
    N'$CollectorName'
);
"@ | Out-Null

            $RowsCollected++
        }

        Invoke-DbaQuery -SqlInstance $CentralSqlInstance -SqlCredential $SqlCredential -Database $CentralDatabase -EnableException -Query @"
UPDATE dbo.CollectionRunHistory
SET [FinishedAt]=SYSDATETIME(),
    [Status]=N'Success',
    [RowsCollected]=$RowsCollected,
    [DurationMs]=DATEDIFF(MILLISECOND,[StartedAt],SYSDATETIME()),
    [ErrorMessage]=NULL
WHERE [CollectionRunId]=$CollectionRunId;
"@ | Out-Null

        Write-Info "Completed $TargetInstance. Rows collected: $RowsCollected"
    }
    catch {
        $err = $_.Exception.Message
        Write-Warn ("Failed collecting SQL operational summary from {0}: {1}" -f $TargetInstance,$err)

        if ($null -ne $CollectionRunId) {
            $safeError = Escape-SqlText $err
            Invoke-DbaQuery -SqlInstance $CentralSqlInstance -SqlCredential $SqlCredential -Database $CentralDatabase -Query @"
UPDATE dbo.CollectionRunHistory
SET [FinishedAt]=SYSDATETIME(),
    [Status]=N'Failed',
    [RowsCollected]=$RowsCollected,
    [DurationMs]=DATEDIFF(MILLISECOND,[StartedAt],SYSDATETIME()),
    [ErrorMessage]=N'$safeError'
WHERE [CollectionRunId]=$CollectionRunId;
"@ | Out-Null
        }
    }
}

Write-Info "$CollectorName completed"
