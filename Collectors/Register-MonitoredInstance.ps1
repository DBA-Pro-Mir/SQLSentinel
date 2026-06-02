<#
===============================================================================
 SQLSentinel - Register Monitored Instance

 Purpose:
   Add or update a SQL Server instance in SQLMonitoring.dbo.MonitoredInstances
   and validate collector connectivity/permissions.
===============================================================================
#>

[CmdletBinding()]
param
(
    [Parameter(Mandatory = $true)]
    [string]$InstanceName,

    [Parameter(Mandatory = $false)]
    [string]$EnvironmentName = "UNKNOWN",

    [Parameter(Mandatory = $false)]
    [string]$CollectionProfile = "Standard",

    [Parameter(Mandatory = $false)]
    [string]$Notes = "",

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = ".\Config\SQLSentinel.config.json",

    [Parameter(Mandatory = $false)]
    [switch]$SkipValidation
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

    $CentralSqlInstance = $config.CentralSqlInstance
    $CentralDatabase = $config.CentralDatabase

    $SqlCredential = $null

    if ($config.SqlCredential.Username -and $config.SqlCredential.Password) {
        $SqlCredential = New-Object System.Management.Automation.PSCredential(
            $config.SqlCredential.Username,
            (ConvertTo-SecureString $config.SqlCredential.Password -AsPlainText -Force)
        )
    }

    Write-Info "Registering monitored SQL instance"
    Write-Info "Target instance: $InstanceName"
    Write-Info "Repository: $CentralSqlInstance / $CentralDatabase"

    if (-not $SkipValidation) {

        Write-Info "Testing SQL connectivity to $InstanceName"

        $connectionTestQuery = @"
SELECT
    ServerName = @@SERVERNAME,
    SqlVersion = CONVERT(nvarchar(128), SERVERPROPERTY('ProductVersion')),
    Edition = CONVERT(nvarchar(128), SERVERPROPERTY('Edition'));
"@

        try {
            $connectionTest = Invoke-DbaQuery `
                -SqlInstance $InstanceName `
                -SqlCredential $SqlCredential `
                -Database master `
                -Query $connectionTestQuery `
                -QueryTimeout 15

            Write-Success "Connection successful: $($connectionTest.ServerName)"
        }
        catch {
            Write-Fail "Could not connect to $InstanceName"
            Write-Warn "Check DNS/hosts file, SQL port, firewall, login, and password."
            throw
        }

        Write-Info "Validating VIEW SERVER STATE permission"

        $permissionQuery = @"
SELECT
    HasViewServerState =
        HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER STATE');
"@

        $permissionResult = Invoke-DbaQuery `
            -SqlInstance $InstanceName `
            -SqlCredential $SqlCredential `
            -Database master `
            -Query $permissionQuery `
            -QueryTimeout 15

        if ([int]$permissionResult.HasViewServerState -ne 1) {
            Write-Warn "VIEW SERVER STATE is missing on $InstanceName"
            Write-Warn "Run this on the monitored server:"
            Write-Host ""
            Write-Host "USE master;"
            Write-Host "GO"
            Write-Host "GRANT VIEW SERVER STATE TO sqlsentinel;"
            Write-Host "GO"
            Write-Host ""
        }
        else {
            Write-Success "VIEW SERVER STATE permission validated."
        }

        Write-Info "Validating msdb read access"

        try {
            Invoke-DbaQuery `
                -SqlInstance $InstanceName `
                -SqlCredential $SqlCredential `
                -Database msdb `
                -Query "SELECT TOP (1) name FROM msdb.dbo.sysjobs;" `
                -QueryTimeout 15 | Out-Null

            Write-Success "msdb SQL Agent metadata access validated."
        }
        catch {
            Write-Warn "msdb read access may be missing on $InstanceName"
            Write-Warn "Run this on the monitored server if SQL Agent collectors are needed:"
            Write-Host ""
            Write-Host "USE msdb;"
            Write-Host "GO"
            Write-Host "CREATE USER sqlsentinel FOR LOGIN sqlsentinel;"
            Write-Host "GO"
            Write-Host "ALTER ROLE db_datareader ADD MEMBER sqlsentinel;"
            Write-Host "GO"
            Write-Host ""
        }
    }

    $safeInstanceName = $InstanceName.Replace("'", "''")
    $safeEnvironmentName = $EnvironmentName.Replace("'", "''")
    $safeCollectionProfile = $CollectionProfile.Replace("'", "''")
    $safeNotes = $Notes.Replace("'", "''")

    $registerQuery = @"
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
        CollectionProfile = N'$safeCollectionProfile',
        Notes = N'$safeNotes',
        IsEnabled = 1,
        ModifiedAt = SYSDATETIME()
    WHERE InstanceName = N'$safeInstanceName';
END
ELSE
BEGIN
    INSERT INTO dbo.MonitoredInstances
    (
        InstanceName,
        EnvironmentName,
        CollectionProfile,
        IsEnabled,
        Notes
    )
    VALUES
    (
        N'$safeInstanceName',
        N'$safeEnvironmentName',
        N'$safeCollectionProfile',
        1,
        N'$safeNotes'
    );
END;

SELECT
    InstanceId,
    InstanceName,
    EnvironmentName,
    CollectionProfile,
    IsEnabled,
    Notes
FROM dbo.MonitoredInstances
WHERE InstanceName = N'$safeInstanceName';
"@

    $registeredInstance = Invoke-DbaQuery `
        -SqlInstance $CentralSqlInstance `
        -SqlCredential $SqlCredential `
        -Database $CentralDatabase `
        -Query $registerQuery `
        -QueryTimeout 30

    Write-Success "Instance registered successfully."

    $registeredInstance | Format-Table -AutoSize

    Write-Info "Recommended next test:"
    Write-Host ".\Collectors\Collect-PerformanceCounters.ps1"
}
catch {
    Write-Fail $_.Exception.Message
    throw
}