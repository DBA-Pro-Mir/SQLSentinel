[CmdletBinding()]
param(
    [string]$ConfigPath = ".\Config\SQLSentinel.config.json",
    [switch]$ContinueOnError = $true
)

$ErrorActionPreference = "Continue"

$Collectors = @(
    ".\Collectors\Collect-PerformanceCounters.ps1",
    ".\Collectors\Collect-DatabaseIO.ps1",
    ".\Collectors\Collect-StorageCapacity.ps1",
    ".\Collectors\Collect-WaitStats.ps1",
    ".\Collectors\Collect-ActiveRequests.ps1",
    ".\Collectors\Collect-Blocking.ps1",
    ".\Collectors\Collect-Deadlocks.ps1",
    ".\Collectors\Collect-Connections.ps1",
    ".\Collectors\Collect-Backups.ps1",
    ".\Collectors\Collect-QueryStats.ps1",
    ".\Collectors\Collect-SqlAgentJobs.ps1",
    ".\Collectors\Collect-SqlAgentAlerts.ps1"
)

$Success = 0
$Failed = 0
$RunStartTime = Get-Date
$CollectorResults = @()

Write-Host ""
Write-Host "============================================================" -ForegroundColor DarkGray
Write-Host "SQLSentinel Collection Started" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor DarkGray
Write-Host ("Started   : {0:yyyy-MM-dd HH:mm:ss}" -f $RunStartTime) -ForegroundColor Cyan
Write-Host ("Collectors: {0}" -f $Collectors.Count) -ForegroundColor Cyan

foreach ($Collector in $Collectors)
{
    $CollectorStartTime = Get-Date
    $CollectorStatus = "Success"
    $CollectorError = $null

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor DarkGray
    Write-Host "Running $Collector" -ForegroundColor Cyan
    Write-Host ("Started : {0:yyyy-MM-dd HH:mm:ss}" -f $CollectorStartTime) -ForegroundColor DarkGray
    Write-Host "============================================================" -ForegroundColor DarkGray

    if (-not (Test-Path $Collector))
    {
        $CollectorStatus = "Failed"
        $CollectorError = "Collector not found"
        $CollectorEndTime = Get-Date
        $CollectorDuration = $CollectorEndTime - $CollectorStartTime

        Write-Warning "Collector not found: $Collector"
        $Failed++

        $CollectorResults += [pscustomobject]@{
            Collector       = [System.IO.Path]::GetFileName($Collector)
            Status          = $CollectorStatus
            Started         = $CollectorStartTime
            Finished        = $CollectorEndTime
            DurationSeconds = [math]::Round($CollectorDuration.TotalSeconds, 2)
            Duration        = $CollectorDuration.ToString("hh\:mm\:ss")
            Error           = $CollectorError
        }

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

        $Success++
    }
    catch
    {
        $CollectorStatus = "Failed"
        $CollectorError = $_.Exception.Message
        $Failed++

        Write-Host "[ERROR] $Collector failed: $CollectorError" -ForegroundColor Red

        if (-not $ContinueOnError)
        {
            $CollectorEndTime = Get-Date
            $CollectorDuration = $CollectorEndTime - $CollectorStartTime

            $CollectorResults += [pscustomobject]@{
                Collector       = [System.IO.Path]::GetFileName($Collector)
                Status          = $CollectorStatus
                Started         = $CollectorStartTime
                Finished        = $CollectorEndTime
                DurationSeconds = [math]::Round($CollectorDuration.TotalSeconds, 2)
                Duration        = $CollectorDuration.ToString("hh\:mm\:ss")
                Error           = $CollectorError
            }

            throw
        }
    }

    $CollectorEndTime = Get-Date
    $CollectorDuration = $CollectorEndTime - $CollectorStartTime

    if ($CollectorStatus -eq "Success")
    {
        Write-Host (
            "[SUCCESS] {0} completed. Start: {1:HH:mm:ss} Finish: {2:HH:mm:ss} Duration: {3}" -f
            $Collector,
            $CollectorStartTime,
            $CollectorEndTime,
            $CollectorDuration.ToString("hh\:mm\:ss")
        ) -ForegroundColor Green
    }

    $CollectorResults += [pscustomobject]@{
        Collector       = [System.IO.Path]::GetFileName($Collector)
        Status          = $CollectorStatus
        Started         = $CollectorStartTime
        Finished        = $CollectorEndTime
        DurationSeconds = [math]::Round($CollectorDuration.TotalSeconds, 2)
        Duration        = $CollectorDuration.ToString("hh\:mm\:ss")
        Error           = $CollectorError
    }
}

$RunEndTime = Get-Date
$RunDuration = $RunEndTime - $RunStartTime

Write-Host ""
Write-Host "============================================================" -ForegroundColor DarkGray
Write-Host "SQLSentinel Collector Duration Summary" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor DarkGray

$CollectorResults |
    Select-Object Collector, Status,
        @{Name="Started"; Expression={$_.Started.ToString("HH:mm:ss")}},
        @{Name="Finished"; Expression={$_.Finished.ToString("HH:mm:ss")}},
        Duration |
    Format-Table -AutoSize

Write-Host ""
Write-Host "============================================================" -ForegroundColor DarkGray
Write-Host "SQLSentinel Collection Summary" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor DarkGray
Write-Host ("Started   : {0:yyyy-MM-dd HH:mm:ss}" -f $RunStartTime) -ForegroundColor Cyan
Write-Host ("Finished  : {0:yyyy-MM-dd HH:mm:ss}" -f $RunEndTime) -ForegroundColor Cyan
Write-Host ("Duration  : {0}" -f $RunDuration.ToString("hh\:mm\:ss")) -ForegroundColor Cyan
Write-Host ("Succeeded : {0}" -f $Success) -ForegroundColor Green
Write-Host ("Failed    : {0}" -f $Failed) -ForegroundColor Yellow
