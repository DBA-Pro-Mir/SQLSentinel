[CmdletBinding()]
param(
    [string]$ConfigPath = ".\Config\SQLSentinel.config.json",
    [switch]$ContinueOnError = $true
)

$ErrorActionPreference = "Continue"

$Collectors = @(
    ".\Collectors\Collect-PerformanceCounters.ps1",
    ".\Collectors\Collect-DatabaseIO.ps1",
    ".\Collectors\Collect-WaitStats.ps1",
    ".\Collectors\Collect-ActiveRequests.ps1",
    ".\Collectors\Collect-Blocking.ps1",
    ".\Collectors\Collect-Connections.ps1",
    ".\Collectors\Collect-Backups.ps1",
    ".\Collectors\Collect-QueryStats.ps1",
    ".\Collectors\Collect-SqlAgentJobs.ps1",
    ".\Collectors\Collect-SqlAgentAlerts.ps1"
)

$Success = 0
$Failed = 0

foreach ($Collector in $Collectors)
{
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor DarkGray
    Write-Host "Running $Collector" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor DarkGray

    if (-not (Test-Path $Collector))
    {
        Write-Warning "Collector not found: $Collector"
        $Failed++
        continue
    }

    try
    {
        # Collectors are PowerShell scripts, not native executables.
        # Do not use $LASTEXITCODE here because it can retain a stale
        # non-zero value from sqlcmd, git, or another native command.
        # A terminating PowerShell error from the collector will be
        # handled by the catch block below.
        & $Collector -ConfigPath $ConfigPath

        Write-Host "[SUCCESS] $Collector completed." -ForegroundColor Green
        $Success++
    }
    catch
    {
        Write-Host "[ERROR] $Collector failed: $($_.Exception.Message)" -ForegroundColor Red
        $Failed++

        if (-not $ContinueOnError)
        {
            throw
        }
    }
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor DarkGray
Write-Host "SQLSentinel Collection Summary" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor DarkGray
Write-Host "Succeeded : $Success" -ForegroundColor Green
Write-Host "Failed    : $Failed" -ForegroundColor Yellow
Write-Host "Finished  : $(Get-Date)"