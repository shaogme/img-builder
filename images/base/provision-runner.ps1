# ==============================================================================
# Script: provision-runner.ps1
# Description: Universal downstream provisioning runner for Windows Server 2025 Core
# Checks for attached payload media and executes child-provision.ps1
# ==============================================================================
$ErrorActionPreference = "Continue"

$lockFile = "C:\tools\runner.lock"
if (Test-Path $lockFile) {
    exit 0
}

# Quick check: Is there any CD-ROM or Removable volume?
$removable = Get-Volume | Where-Object { $_.DriveType -in @('CD-ROM', 'Removable') }
if (!$removable) {
    exit 0
}

Start-Transcript -Path "C:\provision-runner.log" -Append
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " [Runner] Universal Downstream Provisioning Runner" -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Cyan

New-Item -ItemType File -Path $lockFile -Force | Out-Null

$payloadDrive = $null
for ($i = 1; $i -le 10; $i++) {
    $vol = Get-Volume | Where-Object {
        $dl = $_.DriveLetter
        if ($dl) {
            (Test-Path "$($dl):\child-provision.ps1") -and (Test-Path "$($dl):\runner.ready")
        } else {
            $false
        }
    } | Select-Object -First 1
    if ($vol) {
        $payloadDrive = $vol.DriveLetter + ":"
        break
    }
    Write-Host "[Runner] Waiting for payload media to mount (attempt $i/10)..."
    Start-Sleep -Seconds 2
}

if (!$payloadDrive) {
    Write-Host "[Runner] No child provisioning payload detected. Exiting."
    Remove-Item -Force $lockFile -ErrorAction SilentlyContinue
    Stop-Transcript
    exit 0
}

Write-Host "[Runner] Found payload on drive: $payloadDrive" -ForegroundColor Green
$childScript = "$payloadDrive\child-provision.ps1"

Write-Host "[Runner] Invoking child provisioning script: $childScript..." -ForegroundColor Yellow
$proc = Start-Process -FilePath "powershell.exe" -ArgumentList "-ExecutionPolicy Bypass -NoProfile -File `"$childScript`"" -Wait -PassThru -NoNewWindow
$exitCode = $proc.ExitCode
Write-Host "[Runner] Child provisioning process exited with code: $exitCode"

Remove-Item -Force $lockFile -ErrorAction SilentlyContinue

if ($exitCode -eq 0) {
    Write-Host "==================================================" -ForegroundColor Green
    Write-Host " [Runner] Child provisioning SUCCEEDED! Shutting down in 5 seconds..." -ForegroundColor Green
    Write-Host "==================================================" -ForegroundColor Green
    Set-Content -Path "C:\provision-status.txt" -Value "SUCCESS" -Force
    Stop-Transcript
    Start-Sleep -Seconds 5
    Stop-Computer -Force
} else {
    Write-Host "==================================================" -ForegroundColor Red
    Write-Host " [Runner] Child provisioning FAILED with exit code $exitCode!" -ForegroundColor Red
    Write-Host "==================================================" -ForegroundColor Red
    Set-Content -Path "C:\provision-status.txt" -Value "FAILED: $exitCode" -Force
    Stop-Transcript
    Start-Sleep -Seconds 5
    Stop-Computer -Force
}
