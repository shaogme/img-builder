# ==============================================================================
# Script: provision-base.ps1
# Description: Automated base provisioning for Windows Server 2025 Core
# Includes: VirtIO Guest Tools, OpenSSH Server, Downstream Provisioning Runner
# ==============================================================================
$ErrorActionPreference = "Continue"

Start-Transcript -Path "C:\provision-base.log" -Append

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " [Step 1/5] Starting Windows Server 2025 Core Base Provisioning..." -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Cyan

# 1. Locate media drive
$mediaDrive = (Get-Volume | Where-Object { 
    $dl = $_.DriveLetter
    if ($dl) { (Test-Path "$($dl):\provision-base.ps1") -or (Test-Path "$($dl):\provision.ps1") } else { $false }
} | Select-Object -First 1).DriveLetter + ":"
Write-Host "[Info] Deployment media found at drive: $mediaDrive"

# 2. Locate VirtIO drive & install Guest Tools
Write-Host "`n[Step 2/5] Installing VirtIO Guest Tools..." -ForegroundColor Yellow
$virtioDrive = (Get-Volume | Where-Object { 
    $dl = $_.DriveLetter
    if ($dl) { Test-Path "$($dl):\virtio-win-guest-tools.exe" } else { $false }
} | Select-Object -First 1).DriveLetter + ":"
if ($virtioDrive) {
    Write-Host "[Info] Found VirtIO Guest Tools at: $virtioDrive\virtio-win-guest-tools.exe"
    $proc = Start-Process -FilePath "$virtioDrive\virtio-win-guest-tools.exe" -ArgumentList "/install /passive /norestart" -Wait -PassThru
    Write-Host "[Info] VirtIO Guest Tools installer finished with exit code $($proc.ExitCode)"
} else {
    Write-Warning "[Warning] virtio-win-guest-tools.exe not found on any drive!"
}

# 3. Setup tools directory and Downstream Runner
Write-Host "`n[Step 3/5] Setting up C:\tools and Provisioning Runner..." -ForegroundColor Yellow
$toolsDir = "C:\tools"
if (!(Test-Path $toolsDir)) { New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null }

$runnerSrc = "$mediaDrive\provision-runner.ps1"
$runnerDst = "$toolsDir\provision-runner.ps1"
if (Test-Path $runnerSrc) {
    Copy-Item -Path $runnerSrc -Destination $runnerDst -Force
    Write-Host "[Info] Provisioning Runner copied to $runnerDst"
} else {
    Write-Warning "[Warning] $runnerSrc not found on media!"
}

# Register Scheduled Task to execute Runner on startup
Write-Host "[Info] Registering ImageProvisionRunner scheduled task..."
try {
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-ExecutionPolicy Bypass -NoProfile -File C:\tools\provision-runner.ps1'
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName "ImageProvisionRunner" -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
    Write-Host "[Success] ImageProvisionRunner scheduled task registered." -ForegroundColor Green
} catch {
    Write-Warning "[Warning] Failed to register scheduled task: $_"
}

# Also register Run key as backup trigger
try {
    reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" /v "ImageProvisionRunner" /t REG_SZ /d "powershell.exe -ExecutionPolicy Bypass -NoProfile -File C:\tools\provision-runner.ps1" /f | Out-Null
    Write-Host "[Success] Backup Run key registered." -ForegroundColor Green
} catch {
    Write-Warning "[Warning] Failed to register backup Run key: $_"
}

# Ensure persistent AutoLogon in registry and disable SConfig / ServerManager
try {
    $winlogonKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
    Set-ItemProperty -Path $winlogonKey -Name "AutoAdminLogon" -Value "1" -Force
    Set-ItemProperty -Path $winlogonKey -Name "DefaultUserName" -Value "Administrator" -Force
    Set-ItemProperty -Path $winlogonKey -Name "DefaultPassword" -Value "Admin1234!" -Force
    
    # Disable SConfig automatic pop-up
    reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v "AutoAdminLogon" /t REG_SZ /d "1" /f | Out-Null
    reg add "HKLM\SOFTWARE\Microsoft\ServerManager" /v "DoNotOpenServerManagerAtLogon" /t REG_DWORD /d 1 /f | Out-Null
    reg add "HKCU\Software\Microsoft\ServerManager" /v "DoNotOpenServerManagerAtLogon" /t REG_DWORD /d 1 /f | Out-Null
    Set-SConfig -AutoLaunch $false -ErrorAction SilentlyContinue
    Write-Host "[Success] SConfig auto-launch disabled." -ForegroundColor Green
} catch {
    Write-Warning "[Warning] Notice configuring logon settings: $_"
}

# 4. Configure OpenSSH Server
Write-Host "`n[Step 4/5] Enabling OpenSSH Server service..." -ForegroundColor Yellow
try {
    Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 -ErrorAction SilentlyContinue
    Start-Service sshd -ErrorAction SilentlyContinue
    Set-Service -Name sshd -StartupType Automatic -ErrorAction SilentlyContinue
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 -Profile Any -ErrorAction SilentlyContinue
    netsh advfirewall firewall add rule name="OpenSSH-Server-In-TCP" dir=in action=allow protocol=TCP localport=22 profile=any | Out-Null
    Write-Host "[Success] OpenSSH Server enabled on port 22." -ForegroundColor Green
} catch {
    Write-Warning "[Warning] OpenSSH setup notice: $_"
}

# 5. Cleanup & Shutdown
Write-Host "`n[Step 5/5] Performing disk cleanup and shutting down..." -ForegroundColor Yellow
Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\Windows\SoftwareDistribution\Download\*" -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "$env:TEMP\*" -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\Windows\Temp\*" -ErrorAction SilentlyContinue
powercfg -h off
Optimize-Volume -DriveLetter C -Defrag -Verbose -ErrorAction SilentlyContinue

Write-Host "`n==================================================" -ForegroundColor Cyan
Write-Host " Base provisioning completed successfully. Shutting down in 5 seconds." -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Cyan

Stop-Transcript
Start-Sleep -Seconds 5
Stop-Computer -Force
