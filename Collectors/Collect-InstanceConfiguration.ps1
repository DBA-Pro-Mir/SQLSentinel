[CmdletBinding()]
param([string]$ConfigPath = '.\Config\SQLSentinel.config.json')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$CollectorName = 'Collect-InstanceConfiguration'

function Write-Info { param([string]$Message) Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-Fail { param([string]$Message) Write-Host "[ERROR] $Message" -ForegroundColor Red }

function Invoke-SentinelQuery {
    param([string]$SqlInstance,[string]$Database,[string]$Query,[pscredential]$SqlCredential,[int]$QueryTimeout=60,[switch]$AsSingleValue)
    $params = @{ SqlInstance=$SqlInstance; Database=$Database; Query=$Query; QueryTimeout=$QueryTimeout; EnableException=$true }
    if ($null -ne $SqlCredential) { $params.SqlCredential = $SqlCredential }
    if ($AsSingleValue) { $params.As = 'SingleValue' }
    Invoke-DbaQuery @params
}

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
$SqlCredential = $null
if ($config.SqlCredential.Username -and $config.SqlCredential.Password) {
    $SqlCredential = New-Object System.Management.Automation.PSCredential($config.SqlCredential.Username,(ConvertTo-SecureString $config.SqlCredential.Password -AsPlainText -Force))
}

$instances = Invoke-SentinelQuery -SqlInstance $CentralSqlInstance -Database $CentralDatabase -SqlCredential $SqlCredential -Query @"
SELECT [InstanceId], [InstanceName]
FROM dbo.MonitoredInstances
WHERE [IsEnabled] = 1
ORDER BY [InstanceName];
"@

foreach ($instance in $instances) {
    $InstanceId = [int]$instance.InstanceId
    $TargetInstance = [string]$instance.InstanceName
    $CollectionRunId = $null
    $RowsCollected = 0
    $CaptureTime = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

    Write-Info "Collecting instance configuration from $TargetInstance"

    try {
        $CollectionRunId = Invoke-SentinelQuery -SqlInstance $CentralSqlInstance -Database $CentralDatabase -SqlCredential $SqlCredential -AsSingleValue -Query @"
INSERT INTO dbo.CollectionRunHistory ([CollectorName],[InstanceId],[StartedAt],[Status])
OUTPUT inserted.CollectionRunId
VALUES (N'$CollectorName',$InstanceId,SYSDATETIME(),N'Running');
"@

        $version = Invoke-SentinelQuery -SqlInstance $TargetInstance -Database master -SqlCredential $SqlCredential -Query @"
SELECT
    [ProductVersion] = CONVERT(nvarchar(50), SERVERPROPERTY('ProductVersion')),
    [ProductLevel] = CONVERT(nvarchar(50), SERVERPROPERTY('ProductLevel')),
    [Edition] = CONVERT(nvarchar(200), SERVERPROPERTY('Edition')),
    [ProductUpdateLevel] = CONVERT(nvarchar(50), SERVERPROPERTY('ProductUpdateLevel')),
    [ProductUpdateReference] = CONVERT(nvarchar(100), SERVERPROPERTY('ProductUpdateReference'));
"@

        $configRows = @(Invoke-SentinelQuery -SqlInstance $TargetInstance -Database master -SqlCredential $SqlCredential -Query @"
DECLARE @OsMaxMemMB bigint = (SELECT [total_physical_memory_kb] / 1024 FROM sys.dm_os_sys_memory);
DECLARE @SqlMaxMemMB bigint = CONVERT(bigint,@OsMaxMemMB * 0.90);
IF @SqlMaxMemMB < 4096 SET @SqlMaxMemMB = 4096;

WITH [ConfigValues] AS
(
    SELECT *
    FROM (VALUES
        (N'backup compression default',CONVERT(bigint,1)),
        (N'cost threshold for parallelism',CONVERT(bigint,50)),
        (N'max degree of parallelism',CONVERT(bigint,4)),
        (N'max server memory (MB)',@SqlMaxMemMB),
        (N'remote admin connections',CONVERT(bigint,1)),
        (N'Database Mail XPs',CONVERT(bigint,1)),
        (N'optimize for ad hoc workloads',CONVERT(bigint,1)),
        (N'fill factor (%)',CONVERT(bigint,90)),
        (N'xp_cmdshell',CONVERT(bigint,0)),
        (N'clr enabled',CONVERT(bigint,1)),
        (N'show advanced options',CONVERT(bigint,0))
    ) AS [T]([SettingName],[ExpectedValue])
)
SELECT
    [cv].[SettingName],
    [cfg].[description] AS [Description],
    CONVERT(bigint,[cfg].[value_in_use]) AS [CurrentValue],
    [cv].[ExpectedValue],
    CASE WHEN CONVERT(bigint,[cfg].[value_in_use]) = [cv].[ExpectedValue] THEN N'OK' ELSE N'WRONG' END AS [ComplianceStatus]
FROM sys.configurations AS [cfg]
INNER JOIN [ConfigValues] AS [cv] ON [cfg].[name] = [cv].[SettingName]
ORDER BY [cv].[SettingName];
"@)

        $traceRows = @(Invoke-SentinelQuery -SqlInstance $TargetInstance -Database master -SqlCredential $SqlCredential -Query 'DBCC TRACESTATUS(-1) WITH NO_INFOMSGS;')
        $globalTraceFlags = @($traceRows | Where-Object { [int]$_.Global -eq 1 } | ForEach-Object { [string]$_.TraceFlag }) -join ','

        $safeProductVersion = Escape-SqlText $version.ProductVersion
        $safeProductLevel = Escape-SqlText $version.ProductLevel
        $safeEdition = Escape-SqlText $version.Edition
        $safeUpdateLevel = Escape-SqlText $version.ProductUpdateLevel
        $safeUpdateReference = Escape-SqlText $version.ProductUpdateReference
        $safeTraceFlags = Escape-SqlText $globalTraceFlags

        Invoke-SentinelQuery -SqlInstance $CentralSqlInstance -Database $CentralDatabase -SqlCredential $SqlCredential -Query @"
INSERT INTO dbo.InstanceVersionSnapshot
([InstanceId],[CaptureTime],[ProductVersion],[ProductLevel],[Edition],[ProductUpdateLevel],[ProductUpdateReference],[GlobalTraceFlags])
VALUES
($InstanceId,'$CaptureTime',N'$safeProductVersion',N'$safeProductLevel',N'$safeEdition',N'$safeUpdateLevel',N'$safeUpdateReference',NULLIF(N'$safeTraceFlags',N''));
"@ | Out-Null
        $RowsCollected++

        if ($configRows.Count -gt 0) {
            $values = New-Object 'System.Collections.Generic.List[string]'
            foreach ($row in $configRows) {
                $safeSetting = Escape-SqlText $row.SettingName
                $safeDescription = Escape-SqlText $row.Description
                $safeStatus = Escape-SqlText $row.ComplianceStatus
                $currentValue = [long]$row.CurrentValue
                $expectedValue = [long]$row.ExpectedValue
                $values.Add("($InstanceId,'$CaptureTime',N'$safeSetting',N'$safeDescription',$currentValue,$expectedValue,N'$safeStatus')")
            }
            $valueSql = $values -join ','
            Invoke-SentinelQuery -SqlInstance $CentralSqlInstance -Database $CentralDatabase -SqlCredential $SqlCredential -Query @"
INSERT INTO dbo.InstanceConfigurationSnapshot
([InstanceId],[CaptureTime],[SettingName],[Description],[CurrentValue],[ExpectedValue],[ComplianceStatus])
VALUES
$valueSql;
"@ | Out-Null
            $RowsCollected += $configRows.Count
        }

        Invoke-SentinelQuery -SqlInstance $CentralSqlInstance -Database $CentralDatabase -SqlCredential $SqlCredential -Query @"
UPDATE dbo.CollectionRunHistory
SET [FinishedAt]=SYSDATETIME(),[Status]=N'Success',[RowsCollected]=$RowsCollected,
    [DurationMs]=DATEDIFF(MILLISECOND,[StartedAt],SYSDATETIME()),[ErrorMessage]=NULL
WHERE [CollectionRunId]=$CollectionRunId;
"@ | Out-Null

        Write-Info "Completed $TargetInstance. Rows collected: $RowsCollected"
    }
    catch {
        $err = $_.Exception.Message
        Write-Fail "Failed for $TargetInstance: $err"
        if ($null -ne $CollectionRunId) {
            $safeError = Escape-SqlText $err
            Invoke-SentinelQuery -SqlInstance $CentralSqlInstance -Database $CentralDatabase -SqlCredential $SqlCredential -Query @"
UPDATE dbo.CollectionRunHistory
SET [FinishedAt]=SYSDATETIME(),[Status]=N'Failed',[RowsCollected]=$RowsCollected,
    [DurationMs]=DATEDIFF(MILLISECOND,[StartedAt],SYSDATETIME()),[ErrorMessage]=N'$safeError'
WHERE [CollectionRunId]=$CollectionRunId;
"@ | Out-Null
        }
        throw
    }
}

Write-Info "$CollectorName completed"