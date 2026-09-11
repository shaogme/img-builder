# ==============================================================================
# Script: provision-runner.ps1
# Description: Universal downstream provisioning runner for Windows Server 2025 Core
# Checks for attached payload media and executes child-provision.ps1
# ==============================================================================
$ErrorActionPreference = "Continue"

$global:runnerMutex = New-Object System.Threading.Mutex($false, "Global\ImageProvisionRunnerMutex")
if (!$global:runnerMutex.WaitOne(500, $false)) {
    exit 0
}

$lockFile = "C:\tools\runner.lock"
if (Test-Path $lockFile) {
    exit 0
}

Start-Transcript -Path "C:\provision-runner.log" -Append
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " [Runner] Universal Downstream Provisioning Runner" -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Cyan

New-Item -ItemType File -Path $lockFile -Force | Out-Null

$payloadDrive = $null
$layoutDrive = $null

for ($i = 1; $i -le 15; $i++) {
    $volumes = Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveLetter -ne 'C' }
    
    # 查找主执行载荷盘 (PROVISION)
    $provVol = $volumes | Where-Object {
        (Test-Path "$($_.DriveLetter):\child-provision.ps1") -and (Test-Path "$($_.DriveLetter):\runner.ready")
    } | Select-Object -First 1
    
    # 查找可选的离线布局盘 (VS_LAYOUT)
    $layoutVol = $volumes | Where-Object {
        ($_.FileSystemLabel -eq 'VS_LAYOUT') -or (Test-Path "$($_.DriveLetter):\vs_BuildTools.exe") -or (Test-Path "$($_.DriveLetter):\vs_setup.exe")
    } | Select-Object -First 1

    if ($provVol) {
        $payloadDrive = "$($provVol.DriveLetter):"
        if ($layoutVol) { $layoutDrive = "$($layoutVol.DriveLetter):" }
        break
    }
    Write-Host "[Runner] Waiting for payload media to attach (attempt $i/15)..."
    Start-Sleep -Seconds 2
}

if (!$payloadDrive) {
    Write-Host "[Runner] No child provisioning payload detected. Exiting."
    Remove-Item -Force $lockFile -ErrorAction SilentlyContinue
    Stop-Transcript
    exit 0
}

Write-Host "[Runner] Main payload located at: $payloadDrive" -ForegroundColor Green
if ($layoutDrive) {
    Write-Host "[Runner] Detected offline VS layout disk at: $layoutDrive" -ForegroundColor Green
    $env:VS_LAYOUT_DRIVE = $layoutDrive
    [System.Environment]::SetEnvironmentVariable("VS_LAYOUT_DRIVE", $layoutDrive, "Machine")
    [System.Environment]::SetEnvironmentVariable("VS_LAYOUT_DRIVE", $layoutDrive, "Process")
}
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
