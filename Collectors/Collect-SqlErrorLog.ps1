[CmdletBinding()]
param([string]$ConfigPath = '.\Config\SQLSentinel.config.json')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$CollectorName = 'Collect-SqlErrorLog'
$MaximumDailyRows = 10

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
$QueryTimeout = 30

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

    Write-Info "Collecting SQL error log events from $TargetInstance"

    try {
        $CollectionRunId = Invoke-DbaQuery -SqlInstance $CentralSqlInstance -SqlCredential $SqlCredential -Database $CentralDatabase -As SingleValue -EnableException -Query @"
INSERT INTO dbo.CollectionRunHistory ([CollectorName],[InstanceId],[StartedAt],[Status])
OUTPUT inserted.CollectionRunId
VALUES (N'$CollectorName',$InstanceId,SYSDATETIME(),N'Running');
"@

        $severityRows = @(Invoke-DbaQuery -SqlInstance $TargetInstance -SqlCredential $SqlCredential -Database master -Query "EXEC master.dbo.xp_readerrorlog 0, 1, N'Severity';" -QueryTimeout $QueryTimeout -EnableException)
        $failureRows  = @(Invoke-DbaQuery -SqlInstance $TargetInstance -SqlCredential $SqlCredential -Database master -Query "EXEC master.dbo.xp_readerrorlog 0, 1, N'fail';" -QueryTimeout $QueryTimeout -EnableException)

        $today = (Get-Date).Date
        $events = @($severityRows + $failureRows) |
            Where-Object {
                $null -ne $_.LogDate -and
                -not [System.DBNull]::Value.Equals($_.LogDate) -and
                ([datetime]$_.LogDate) -ge $today
            } |
            Sort-Object @{Expression={ [datetime]$_.LogDate }; Descending=$true} |
            Group-Object {
                ('{0:O}|{1}|{2}' -f ([datetime]$_.LogDate), [string]$_.ProcessInfo, [string]$_.Text)
            } |
            ForEach-Object { $_.Group[0] } |
            Select-Object -First $MaximumDailyRows

        foreach ($event in $events) {
            $eventTime = ([datetime]$event.LogDate).ToString('yyyy-MM-dd HH:mm:ss')
            $processInfo = Escape-SqlText $event.ProcessInfo
            $message = Escape-SqlText $event.Text
            $severity = if ([string]$event.Text -match '(?i)severity\s+(2[0-5]|1[7-9])') { 'Critical' } else { 'Warning' }

            $details = Escape-SqlText ("ProcessInfo: {0}`nMessage: {1}" -f [string]$event.ProcessInfo,[string]$event.Text)

            $inserted = Invoke-DbaQuery -SqlInstance $CentralSqlInstance -SqlCredential $SqlCredential -Database $CentralDatabase -As SingleValue -EnableException -Query @"
IF NOT EXISTS
(
    SELECT 1
    FROM dbo.MetricTextSnapshot
    WHERE [InstanceId] = $InstanceId
      AND [CaptureTime] = '$eventTime'
      AND [MetricCategory] = N'SqlErrorLog'
      AND [DetailType] = N'ErrorLogEvent'
      AND [Details] = N'$details'
      AND [SourceCollector] = N'$CollectorName'
)
BEGIN
    INSERT INTO dbo.MetricTextSnapshot
    ([InstanceId],[CaptureTime],[MetricCategory],[DetailType],[Severity],[Details],[SourceCollector])
    VALUES
    ($InstanceId,'$eventTime',N'SqlErrorLog',N'ErrorLogEvent',N'$severity',N'$details',N'$CollectorName');
    SELECT Inserted = 1;
END
ELSE
BEGIN
    SELECT Inserted = 0;
END;
"@

            if ([int]$inserted -eq 1) { $RowsCollected++ }
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
        Write-Warn ("Failed collecting SQL error log from {0}: {1}" -f $TargetInstance,$err)
        if ($null -ne $CollectionRunId) {
            $safeError = Escape-SqlText $err
            Invoke-DbaQuery -SqlInstance $CentralSqlInstance -SqlCredential $SqlCredential -Database $CentralDatabase -Query @"
UPDATE dbo.CollectionRunHistory
SET [FinishedAt]=SYSDATETIME(),[Status]=N'Failed',[RowsCollected]=$RowsCollected,
    [DurationMs]=DATEDIFF(MILLISECOND,[StartedAt],SYSDATETIME()),[ErrorMessage]=N'$safeError'
WHERE [CollectionRunId]=$CollectionRunId;
"@ | Out-Null
        }
    }
}

Write-Info "$CollectorName completed"