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
        & $Collector -ConfigPath $ConfigPath

        if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE)
        {
            throw "Collector exited with code $LASTEXITCODE"
        }

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