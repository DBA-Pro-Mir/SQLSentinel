<#
.SYNOPSIS
Lists SQLSentinel monitored instances and their operational state.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [ValidateSet('All','Enabled','Disabled')]
    [string]$Status = 'All',

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

$where = switch ($Status) {
    'Enabled'  { 'WHERE IsEnabled = 1' }
    'Disabled' { 'WHERE IsEnabled = 0' }
    default    { '' }
}

$query = @"
SELECT InstanceId, InstanceName, EnvironmentName, IsEnabled,
       CollectionProfile, ComplianceProfile, SqlVersion, Edition,
       CreatedAt, ModifiedAt, Notes
FROM dbo.MonitoredInstances
$where
ORDER BY EnvironmentName, InstanceName;
"@

Invoke-DbaQuery -SqlInstance $CentralSqlInstance -SqlCredential $SqlCredential -Database $CentralDatabase -Query $query -QueryTimeout 30 -EnableException |
    Format-Table -AutoSize
