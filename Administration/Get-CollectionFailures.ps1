<#
.SYNOPSIS
Shows recent SQLSentinel collection failures and long-running incomplete collection runs.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [ValidateRange(1,720)]
    [int]$Hours = 24,

    [Parameter(Mandatory=$false)]
    [ValidateRange(1,1000)]
    [int]$Top = 100,

    [Parameter(Mandatory=$false)]
    [string]$SqlInstance,

    [Parameter(Mandatory=$false)]
    [string]$CollectorName,

    [Parameter(Mandatory=$false)]
    [ValidateRange(1,1440)]
    [int]$RunningOlderThanMinutes = 15,

    [Parameter(Mandatory=$false)]
    [string]$ConfigPath = '.\Config\SQLSentinel.config.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ConfigPath)) { throw "Config file not found: $ConfigPath" }
if (-not (Get-Module -ListAvailable -Name dbatools)) { throw 'dbatools module is not installed.' }
Import-Module dbatools

$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$CentralSqlInstance = [string]$config.CentralSqlInstance
$CentralDatabase = [string]$config.CentralDatabase

$SqlCredential = $null
if ($null -ne $config.SqlCredential -and $config.SqlCredential.Username -and $config.SqlCredential.Password) {
    $SqlCredential = New-Object System.Management.Automation.PSCredential(
        $config.SqlCredential.Username,
        (ConvertTo-SecureString $config.SqlCredential.Password -AsPlainText -Force)
    )
}

$safeInstance = $SqlInstance.Replace("'", "''")
$safeCollector = $CollectorName.Replace("'", "''")
$instanceFilter = if ([string]::IsNullOrWhiteSpace($SqlInstance)) { '' } else { "AND mi.InstanceName = N'$safeInstance'" }
$collectorFilter = if ([string]::IsNullOrWhiteSpace($CollectorName)) { '' } else { "AND crh.CollectorName = N'$safeCollector'" }

$query = @"
SET NOCOUNT ON;

SELECT TOP ($Top)
    crh.CollectionRunId,
    mi.InstanceName,
    crh.CollectorName,
    crh.StartedAt,
    crh.FinishedAt,
    crh.Status,
    crh.RowsCollected,
    crh.DurationMs,
    crh.ErrorMessage
FROM dbo.CollectionRunHistory AS crh
INNER JOIN dbo.MonitoredInstances AS mi
    ON mi.InstanceId = crh.InstanceId
WHERE crh.StartedAt >= DATEADD(HOUR, -$Hours, SYSDATETIME())
  AND
  (
      crh.Status NOT IN ('Completed', 'Success', 'Succeeded')
      OR
      (
          crh.Status = 'Running'
          AND crh.StartedAt < DATEADD(MINUTE, -$RunningOlderThanMinutes, SYSDATETIME())
      )
  )
  $instanceFilter
  $collectorFilter
ORDER BY crh.StartedAt DESC;
"@

Write-Host "[INFO] Repository: $CentralSqlInstance / $CentralDatabase" -ForegroundColor Cyan
Write-Host "[INFO] Showing collection failures from the last $Hours hour(s)." -ForegroundColor Cyan

$result = Invoke-DbaQuery `
    -SqlInstance $CentralSqlInstance `
    -SqlCredential $SqlCredential `
    -Database $CentralDatabase `
    -Query $query `
    -QueryTimeout 30 `
    -EnableException

if ($null -eq $result -or @($result).Count -eq 0) {
    Write-Host '[SUCCESS] No matching failed or stale collection runs found.' -ForegroundColor Green
}
else {
    $result | Format-Table -AutoSize -Wrap
}
