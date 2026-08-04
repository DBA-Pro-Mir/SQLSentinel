<#
===============================================================================
 SQLSentinel - Register Monitored Instance
===============================================================================
 Validates a SQL Server instance and inserts or updates its inventory record in
 dbo.MonitoredInstances, including backup compliance and platform metadata.
#>

[CmdletBinding()]
param
(
    [Parameter(Mandatory = $true)]
    [string]$SqlInstance,

    [Parameter(Mandatory = $true)]
    [string]$EnvironmentName,

    [Parameter(Mandatory = $false)]
    [string]$CollectionProfile = "Standard",

    [Parameter(Mandatory = $false)]
    [ValidateSet("V1_SIMPLE", "V2_FULL")]
    [string]$ComplianceProfile = "V1_SIMPLE",

    [Parameter(Mandatory = $false)]
    [string]$Notes = "",

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = ".\Config\SQLSentinel.config.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Info { param([string]$Message) Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-Success { param([string]$Message) Write-Host "[SUCCESS] $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Write-Fail { param([string]$Message) Write-Host "[ERROR] $Message" -ForegroundColor Red }

try {
    if (-not (Test-Path $ConfigPath)) {
        throw "Config file not found: $ConfigPath"
    }

    if (-not (Get-Module -ListAvailable -Name dbatools)) {
        throw "dbatools module is not installed."
    }

    Import-Module dbatools

    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    $CentralSqlInstance = [string]$config.CentralSqlInstance
    $CentralDatabase = [string]$config.CentralDatabase

    $SqlCredential = $null

    if ($null -ne $config.SqlCredential -and
        $config.SqlCredential.Username -and
        $config.SqlCredential.Password) {

        $SqlCredential = New-Object System.Management.Automation.PSCredential(
            $config.SqlCredential.Username,
            (ConvertTo-SecureString $config.SqlCredential.Password -AsPlainText -Force)
        )
    }

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor DarkCyan
    Write-Host " SQLSentinel - Register Monitored Instance" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor DarkCyan
    Write-Info "Target instance: $SqlInstance"
    Write-Info "Repository: $CentralSqlInstance / $CentralDatabase"
    Write-Info "Collection profile: $CollectionProfile"
    Write-Info "Backup compliance profile: $ComplianceProfile"

    Write-Info "Testing SQL connectivity"

    $serverInfo = Invoke-DbaQuery `
        -SqlInstance $SqlInstance `
        -SqlCredential $SqlCredential `
        -Database master `
        -Query @"
SELECT
    ServerName = CAST(SERVERPROPERTY('ServerName') AS nvarchar(128)),
    ProductVersion = CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)),
    ProductLevel = CAST(SERVERPROPERTY('ProductLevel') AS nvarchar(128)),
    Edition = CAST(SERVERPROPERTY('Edition') AS nvarchar(256)),
    UserDatabaseCount =
    (
        SELECT COUNT(*)
        FROM sys.databases
        WHERE database_id > 4
          AND state_desc = 'ONLINE'
    ),
    CpuCount = osi.cpu_count,
    PhysicalMemoryMB = osi.physical_memory_kb / 1024
FROM sys.dm_os_sys_info AS osi;
"@ `
        -QueryTimeout 30 `
        -EnableException

    $server = $serverInfo | Select-Object -First 1

    if ($null -eq $server) {
        throw "Connectivity validation returned no server information."
    }

    Write-Success "Connection successful: $($server.ServerName)"
    Write-Info "Version: $($server.ProductVersion) $($server.ProductLevel)"
    Write-Info "Edition: $($server.Edition)"
    Write-Info "Online user databases: $($server.UserDatabaseCount)"
    Write-Info "CPU count: $($server.CpuCount)"
    Write-Info "Physical memory: $($server.PhysicalMemoryMB) MB"

    Write-Info "Validating VIEW SERVER STATE permission"

    $permissionResult = Invoke-DbaQuery `
        -SqlInstance $SqlInstance `
        -SqlCredential $SqlCredential `
        -Database master `
        -Query "SELECT HasViewServerState = HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER STATE');" `
        -QueryTimeout 15 `
        -EnableException

    if ([int]$permissionResult.HasViewServerState -ne 1) {
        throw "The monitoring login does not have VIEW SERVER STATE on $SqlInstance."
    }

    Write-Success "VIEW SERVER STATE permission validated."

    Write-Info "Validating msdb SQL Agent metadata access"

    try {
        $null = Invoke-DbaQuery `
            -SqlInstance $SqlInstance `
            -SqlCredential $SqlCredential `
            -Database msdb `
            -Query "SELECT TOP (1) job_id, name FROM dbo.sysjobs;" `
            -QueryTimeout 15 `
            -EnableException

        Write-Success "msdb SQL Agent metadata access validated."
    }
    catch {
        Write-Warn "SQL Agent metadata validation failed: $($_.Exception.Message)"
        Write-Warn "Registration will continue, but SQL Agent collectors may fail until msdb permissions are granted."
    }

    $safeInstanceName = $SqlInstance.Replace("'", "''")
    $safeEnvironmentName = $EnvironmentName.Replace("'", "''")
    $safeCollectionProfile = $CollectionProfile.Replace("'", "''")
    $safeComplianceProfile = $ComplianceProfile.Replace("'", "''")
    $safeNotes = $Notes.Replace("'", "''")
    $safeSqlVersion = ([string]$server.ProductVersion).Replace("'", "''")
    $safeEdition = ([string]$server.Edition).Replace("'", "''")

    Write-Info "Registering instance in SQLMonitoring"

    $registrationResult = Invoke-DbaQuery `
        -SqlInstance $CentralSqlInstance `
        -SqlCredential $SqlCredential `
        -Database $CentralDatabase `
        -Query @"
SET NOCOUNT ON;

IF COL_LENGTH('dbo.MonitoredInstances', 'ComplianceProfile') IS NULL
    THROW 50001, 'Column dbo.MonitoredInstances.ComplianceProfile does not exist.', 1;

IF COL_LENGTH('dbo.MonitoredInstances', 'ModifiedAt') IS NULL
    THROW 50002, 'Column dbo.MonitoredInstances.ModifiedAt does not exist.', 1;

IF COL_LENGTH('dbo.MonitoredInstances', 'SqlVersion') IS NULL
    THROW 50003, 'Column dbo.MonitoredInstances.SqlVersion does not exist.', 1;

IF COL_LENGTH('dbo.MonitoredInstances', 'Edition') IS NULL
    THROW 50004, 'Column dbo.MonitoredInstances.Edition does not exist.', 1;

IF EXISTS
(
    SELECT 1
    FROM dbo.MonitoredInstances
    WHERE InstanceName = N'$safeInstanceName'
)
BEGIN
    UPDATE dbo.MonitoredInstances
    SET
        EnvironmentName = N'$safeEnvironmentName',
        IsEnabled = 1,
        CollectionProfile = N'$safeCollectionProfile',
        ComplianceProfile = N'$safeComplianceProfile',
        SqlVersion = N'$safeSqlVersion',
        Edition = N'$safeEdition',
        Notes = N'$safeNotes',
        ModifiedAt = SYSDATETIME()
    WHERE InstanceName = N'$safeInstanceName';
END
ELSE
BEGIN
    INSERT INTO dbo.MonitoredInstances
    (
        InstanceName,
        EnvironmentName,
        IsEnabled,
        CollectionProfile,
        ComplianceProfile,
        SqlVersion,
        Edition,
        Notes,
        CreatedAt,
        ModifiedAt
    )
    VALUES
    (
        N'$safeInstanceName',
        N'$safeEnvironmentName',
        1,
        N'$safeCollectionProfile',
        N'$safeComplianceProfile',
        N'$safeSqlVersion',
        N'$safeEdition',
        N'$safeNotes',
        SYSDATETIME(),
        SYSDATETIME()
    );
END;

SELECT
    InstanceId,
    InstanceName,
    EnvironmentName,
    CollectionProfile,
    ComplianceProfile,
    SqlVersion,
    Edition,
    IsEnabled,
    Notes,
    CreatedAt,
    ModifiedAt
FROM dbo.MonitoredInstances
WHERE InstanceName = N'$safeInstanceName';
"@ `
        -QueryTimeout 30 `
        -EnableException

    Write-Success "Instance registered successfully."
    Write-Host ""
    $registrationResult | Format-Table -AutoSize
}
catch {
    Write-Fail $_.Exception.Message
    throw
}
