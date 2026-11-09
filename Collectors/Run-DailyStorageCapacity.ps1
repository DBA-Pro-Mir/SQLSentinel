[CmdletBinding()]
param(
    [string]$ConfigPath = ".\Config\SQLSentinel.config.json"
)

$ErrorActionPreference = "Stop"

# SQLSentinel runs against internal SQL Servers whose TLS certificates may not
# chain to a CA trusted by the SQL Server Agent service account. Keep encryption
# enabled, but trust the server certificate for this PowerShell session.
Import-Module dbatools -ErrorAction Stop
Set-DbatoolsConfig -FullName 'sql.connection.trustcert' -Value $true


$StartTime = Get-Date

Write-Host ""
Write-Host "============================================================" -ForegroundColor DarkGray
Write-Host "SQLSentinel Daily Storage Capacity Collection" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor DarkGray
Write-Host ("Started  : {0:yyyy-MM-dd HH:mm:ss}" -f $StartTime) -ForegroundColor Cyan

try {
    & ".\Collectors\Collect-StorageCapacity.ps1" -ConfigPath $ConfigPath

    $EndTime = Get-Date
    $Duration = $EndTime - $StartTime

    Write-Host ""
    Write-Host ("Finished : {0:yyyy-MM-dd HH:mm:ss}" -f $EndTime) -ForegroundColor Cyan
    Write-Host ("Duration : {0}" -f $Duration.ToString("hh\:mm\:ss")) -ForegroundColor Cyan
    Write-Host "Status   : Success" -ForegroundColor Green
}
catch {
    $EndTime = Get-Date
    $Duration = $EndTime - $StartTime

    Write-Host ""
    Write-Host ("Finished : {0:yyyy-MM-dd HH:mm:ss}" -f $EndTime) -ForegroundColor Cyan
    Write-Host ("Duration : {0}" -f $Duration.ToString("hh\:mm\:ss")) -ForegroundColor Cyan
    Write-Host ("Status   : Failed - {0}" -f $_.Exception.Message) -ForegroundColor Red
    throw
}
