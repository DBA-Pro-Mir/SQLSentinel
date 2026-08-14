<#
===============================================================================
 SQLSentinel - Performance Counter Collector
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

$CollectorName = "Collect-PerformanceCounters"

function Write-Info { param([string]$Message) Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-Warn { param([string]$Message) Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Write-Fail { param([string]$Message) Write-Host "[ERROR] $Message" -ForegroundColor Red }

function Start-CollectionRun {
    param([string]$CentralSqlInstance,[string]$CentralDatabase,[pscredential]$SqlCredential,[int]$InstanceId,[string]$CollectorName)
    Invoke-DbaQuery -SqlInstance $CentralSqlInstance -SqlCredential $SqlCredential -Database $CentralDatabase -Query @"
INSERT INTO dbo.CollectionRunHistory (CollectorName,InstanceId,StartedAt,Status)
OUTPUT inserted.CollectionRunId
VALUES ('$CollectorName',$InstanceId,SYSDATETIME(),'Running');
"@ -As SingleValue
}

function Complete-CollectionRun {
    param([string]$CentralSqlInstance,[string]$CentralDatabase,[pscredential]$SqlCredential,[bigint]$CollectionRunId,[string]$Status,[int]$RowsCollected,[string]$ErrorMessage=$null)
    $safeError = if ($null -eq $ErrorMessage) { "NULL" } else { "N'" + $ErrorMessage.Replace("'", "''") + "'" }
    Invoke-DbaQuery -SqlInstance $CentralSqlInstance -SqlCredential $SqlCredential -Database $CentralDatabase -Query @"
UPDATE dbo.CollectionRunHistory
SET FinishedAt=SYSDATETIME(),Status='$Status',RowsCollected=$RowsCollected,
    DurationMs=DATEDIFF(MILLISECOND,StartedAt,SYSDATETIME()),ErrorMessage=$safeError
WHERE CollectionRunId=$CollectionRunId;
"@ | Out-Null
}

try {
    if (-not (Test-Path $ConfigPath)) { throw "Config file not found: $ConfigPath" }
    if (-not (Get-Module -ListAvailable -Name dbatools)) { throw "dbatools module is not installed." }
    Import-Module dbatools

    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    $CentralSqlInstance = $config.CentralSqlInstance
    $CentralDatabase = $config.CentralDatabase
    $QueryTimeout = $config.Collectors.PerformanceCounters.QueryTimeoutSeconds

    $SqlCredential = $null
    if ($config.SqlCredential.Username -and $config.SqlCredential.Password) {
        $SqlCredential = New-Object System.Management.Automation.PSCredential(
            $config.SqlCredential.Username,
            (ConvertTo-SecureString $config.SqlCredential.Password -AsPlainText -Force)
        )
    }

    Write-Info "Starting $CollectorName"
    Write-Info "Repository: $CentralSqlInstance / $CentralDatabase"

    $instances = Invoke-DbaQuery -SqlInstance $CentralSqlInstance -SqlCredential $SqlCredential -Database $CentralDatabase -Query @"
SELECT InstanceId,InstanceName
FROM dbo.MonitoredInstances
WHERE IsEnabled=1
ORDER BY InstanceName;
"@ -QueryTimeout 30

    foreach ($instance in $instances) {
        $InstanceId = [int]$instance.InstanceId
        $TargetInstance = [string]$instance.InstanceName
        $RowsCollected = 0
        $CollectionRunId = $null
        Write-Info "Collecting performance counters from $TargetInstance"

        try {
            $CollectionRunId = Start-CollectionRun -CentralSqlInstance $CentralSqlInstance -CentralDatabase $CentralDatabase -SqlCredential $SqlCredential -InstanceId $InstanceId -CollectorName $CollectorName

            $counterQuery = @"
SELECT SYSDATETIME() AS CaptureTime,object_name AS ObjectName,counter_name AS CounterName,
       instance_name AS InstanceName,cntr_value AS CounterValue,cntr_type AS CounterType
FROM sys.dm_os_performance_counters
WHERE counter_name IN
(
 'Batch Requests/sec','SQL Compilations/sec','SQL Re-Compilations/sec','User Connections',
 'Logins/sec','Logouts/sec','Lock Waits/sec','Number of Deadlocks/sec','Page reads/sec',
 'Page writes/sec','Lazy Writes/sec','Checkpoint pages/sec','Memory Grants Pending',
 'Target Server Memory (KB)','Total Server Memory (KB)','Page life expectancy'
);
"@
            $counters = Invoke-DbaQuery -SqlInstance $TargetInstance -SqlCredential $SqlCredential -Database master -Query $counterQuery -QueryTimeout $QueryTimeout -EnableException

            foreach ($counter in $counters) {
                $ObjectName = $counter.ObjectName.Replace("'", "''")
                $CounterName = $counter.CounterName.Replace("'", "''")
                $CounterInstanceName = if ([string]::IsNullOrWhiteSpace($counter.InstanceName)) { "NULL" } else { "N'" + $counter.InstanceName.Replace("'", "''") + "'" }
                $MetricValue = [decimal]$counter.CounterValue
                $MetricType = switch ($counter.CounterName) {
                    "User Connections" { "Gauge" }
                    "Memory Grants Pending" { "Gauge" }
                    "Target Server Memory (KB)" { "Gauge" }
                    "Total Server Memory (KB)" { "Gauge" }
                    "Page life expectancy" { "Gauge" }
                    default { "Cumulative" }
                }
                $Unit = switch -Wildcard ($counter.CounterName) {
                    "*Memory*KB*" { "KB" }
                    "Page life expectancy" { "sec" }
                    default { "count" }
                }
                $CaptureTime = ([datetime]$counter.CaptureTime).ToString("yyyy-MM-dd HH:mm:ss")

                Invoke-DbaQuery -SqlInstance $CentralSqlInstance -SqlCredential $SqlCredential -Database $CentralDatabase -Query @"
INSERT INTO dbo.MetricSnapshot
(InstanceId,CaptureTime,DatabaseName,ObjectName,CounterName,InstanceName,MetricCategory,MetricValue,MetricType,Unit,SourceCollector)
VALUES
($InstanceId,'$CaptureTime',NULL,N'$ObjectName',N'$CounterName',$CounterInstanceName,'PerformanceCounter',$MetricValue,'$MetricType','$Unit','$CollectorName');
"@ -QueryTimeout 30 | Out-Null
                $RowsCollected++
            }

            # Capture explicit CPU percentages from the latest scheduler monitor sample.
            # These are point-in-time percentages and can be evaluated directly by reporting.
            $cpu = Invoke-DbaQuery -SqlInstance $TargetInstance -SqlCredential $SqlCredential -Database master -Query @"
;WITH rb AS
(
    SELECT TOP (1)
        CaptureTime = SYSDATETIME(),
        RecordXml = CONVERT(xml, record)
    FROM sys.dm_os_ring_buffers
    WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR'
      AND record LIKE N'%<SystemHealth>%'
    ORDER BY [timestamp] DESC
)
SELECT
    CaptureTime,
    SqlProcessCpuPercent = RecordXml.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]','int'),
    SystemIdlePercent = RecordXml.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]','int'),
    SystemCpuPercent = 100 - RecordXml.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]','int')
FROM rb;
"@ -QueryTimeout $QueryTimeout -EnableException | Select-Object -First 1

            if ($null -ne $cpu) {
                $cpuCapture = ([datetime]$cpu.CaptureTime).ToString("yyyy-MM-dd HH:mm:ss")
                $cpuMetrics = @(
                    @{ Name="SqlProcessCpuPercent"; Value=[decimal]$cpu.SqlProcessCpuPercent },
                    @{ Name="SystemCpuPercent"; Value=[decimal]$cpu.SystemCpuPercent },
                    @{ Name="SystemIdlePercent"; Value=[decimal]$cpu.SystemIdlePercent }
                )
                foreach ($metric in $cpuMetrics) {
                    Invoke-DbaQuery -SqlInstance $CentralSqlInstance -SqlCredential $SqlCredential -Database $CentralDatabase -Query @"
INSERT INTO dbo.MetricSnapshot
(InstanceId,CaptureTime,DatabaseName,ObjectName,CounterName,InstanceName,MetricCategory,MetricValue,MetricType,Unit,SourceCollector)
VALUES
($InstanceId,'$cpuCapture',NULL,N'CPU',N'$($metric.Name)',NULL,'PerformanceCounter',$($metric.Value),'Gauge','percent','$CollectorName');
"@ -QueryTimeout 30 | Out-Null
                    $RowsCollected++
                }
            }

            Complete-CollectionRun -CentralSqlInstance $CentralSqlInstance -CentralDatabase $CentralDatabase -SqlCredential $SqlCredential -CollectionRunId $CollectionRunId -Status "Success" -RowsCollected $RowsCollected
            Write-Info "Completed $TargetInstance. Rows collected: $RowsCollected"
        }
        catch {
            $errorMessage = $_.Exception.Message
            Write-Warn "Failed collecting from $TargetInstance. $errorMessage"
            if ($null -ne $CollectionRunId) {
                Complete-CollectionRun -CentralSqlInstance $CentralSqlInstance -CentralDatabase $CentralDatabase -SqlCredential $SqlCredential -CollectionRunId $CollectionRunId -Status "Failed" -RowsCollected $RowsCollected -ErrorMessage $errorMessage
            }
        }
    }
    Write-Info "$CollectorName completed."
}
catch {
    Write-Fail $_.Exception.Message
    throw
}
