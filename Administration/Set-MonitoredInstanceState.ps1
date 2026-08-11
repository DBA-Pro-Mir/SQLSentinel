<#
.SYNOPSIS
Enables or disables collection for a registered SQLSentinel instance.

.DESCRIPTION
Updates dbo.MonitoredInstances.IsEnabled without deleting the instance or its historical monitoring data.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$SqlInstance,

    [Parameter(Mandatory=$true)]
    [ValidateSet('Enable','Disable')]
    [string]$State,

    [Parameter(Mandatory=$false)]
    [string]$Reason = '',

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
$safeReason = $Reason.Replace("'", "''")
$enabled = if ($State -eq 'Enable') { 1 } else { 0 }

$query = @"
SET NOCOUNT ON;
IF NOT EXISTS (SELECT 1 FROM dbo.MonitoredInstances WHERE InstanceName = N'$safeInstance')
    THROW 50010, 'The specified instance is not registered in SQLSentinel.', 1;

UPDATE dbo.MonitoredInstances
SET IsEnabled = $enabled,
    ModifiedAt = SYSDATETIME(),
    Notes = CASE
              WHEN N'$safeReason' = N'' THEN Notes
              WHEN Notes IS NULL OR Notes = N'' THEN N'$safeReason'
              ELSE Notes + N' | ' + N'$safeReason'
            END
WHERE InstanceName = N'$safeInstance';

SELECT InstanceId, InstanceName, EnvironmentName, CollectionProfile,
       ComplianceProfile, IsEnabled, Notes, ModifiedAt
FROM dbo.MonitoredInstances
WHERE InstanceName = N'$safeInstance';
"@

$result = Invoke-DbaQuery -SqlInstance $CentralSqlInstance -SqlCredential $SqlCredential -Database $CentralDatabase -Query $query -QueryTimeout 30 -EnableException
Write-Host "[SUCCESS] $SqlInstance monitoring state set to $State." -ForegroundColor Green
$result | Format-Table -AutoSize
