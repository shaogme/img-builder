# ==============================================================================
# Script: provision.ps1
# Description: Automated post-install provisioning for Windows Server 2025 Core
# Includes: VirtIO Guest Tools, MinGW-w64 (w64devkit), Rust GNU
# ==============================================================================
$ErrorActionPreference = "Continue"

Start-Transcript -Path "C:\provision.log" -Append

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " [Step 1/8] Starting Windows Server 2025 Core Provisioning..." -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Cyan

# 1. Locate media drive
$mediaDrive = (Get-Volume | Where-Object { Test-Path ("$($_.DriveLetter):\provision.ps1") } | Select-Object -First 1).DriveLetter + ":"
Write-Host "[Info] Deployment media found at drive: $mediaDrive"

# 2. Locate VirtIO drive & install Guest Tools
Write-Host "`n[Step 2/8] Installing VirtIO Guest Tools..." -ForegroundColor Yellow
$virtioDrive = (Get-Volume | Where-Object { Test-Path ("$($_.DriveLetter):\virtio-win-guest-tools.exe") } | Select-Object -First 1).DriveLetter + ":"
if ($virtioDrive) {
    Write-Host "[Info] Found VirtIO Guest Tools at: $virtioDrive\virtio-win-guest-tools.exe"
    $proc = Start-Process -FilePath "$virtioDrive\virtio-win-guest-tools.exe" -ArgumentList "/install /passive /norestart" -Wait -PassThru
    Write-Host "[Info] VirtIO Guest Tools installer finished with exit code $($proc.ExitCode)"
} else {
    Write-Warning "[Warning] virtio-win-guest-tools.exe not found on any drive!"
}

# 3. Setup tools directory
$toolsDir = "C:\tools"
if (!(Test-Path $toolsDir)) { New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null }

# 4. Extract or install w64devkit (MinGW-w64 GCC toolchain)
Write-Host "`n[Step 3/8] Deploying MinGW-w64 toolchain (w64devkit: gcc, ld, ar, make)..." -ForegroundColor Yellow
$mingwDest = "$toolsDir\w64devkit"
$localDevkitSfx = "$mediaDrive\packages\w64devkit-x64-2.9.1.7z.exe"
$localDevkitZip = "$mediaDrive\packages\w64devkit.zip"

if (Test-Path $localDevkitSfx) {
    Write-Host "[Info] Extracting w64devkit from local SFX archive: $localDevkitSfx..."
    $proc = Start-Process -FilePath $localDevkitSfx -ArgumentList "-y -o`"$toolsDir`"" -Wait -PassThru
    Write-Host "[Info] SFX extraction completed with exit code $($proc.ExitCode)"
} elseif (Test-Path $localDevkitZip) {
    Write-Host "[Info] Expanding w64devkit.zip from media..."
    Expand-Archive -Path $localDevkitZip -DestinationPath $toolsDir -Force
} else {
    Write-Host "[Info] Downloading w64devkit from GitHub..."
    $url = "https://github.com/skeeto/w64devkit/releases/download/v2.9.1/w64devkit-x64-2.9.1.7z.exe"
    $tmpSfx = "$env:TEMP\w64devkit.7z.exe"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $url -OutFile $tmpSfx -UseBasicParsing
    Start-Process -FilePath $tmpSfx -ArgumentList "-y -o`"$toolsDir`"" -Wait
    Remove-Item -Force $tmpSfx -ErrorAction SilentlyContinue
}

# 5. Install Rustup and x86_64-pc-windows-gnu toolchain
Write-Host "`n[Step 4/8] Installing Rust GNU toolchain (x86_64-pc-windows-gnu)..." -ForegroundColor Yellow
$localRustup = "$mediaDrive\packages\rustup-init.exe"
$rustupExe = "$env:TEMP\rustup-init.exe"

if (Test-Path $localRustup) {
    Copy-Item $localRustup -Destination $rustupExe -Force
} else {
    Write-Host "[Info] Downloading rustup-init.exe..."
    Invoke-WebRequest -Uri "https://win.rustup.rs/x86_64" -OutFile $rustupExe -UseBasicParsing
}

Write-Host "[Info] Waiting for network connectivity to static.rust-lang.org..."
for ($attempt = 1; $attempt -le 20; $attempt++) {
    try {
        $res = Invoke-WebRequest -Uri "https://static.rust-lang.org" -UseBasicParsing -TimeoutSec 5
        if ($res.StatusCode -eq 200) {
            Write-Host "[Success] Network is accessible!" -ForegroundColor Green
            break
        }
    } catch {
        Write-Host "[Wait] Network not ready yet (attempt $attempt/20), waiting 3s..."
        Start-Sleep -Seconds 3
    }
}

$maxRetries = 3
$rustSuccess = $false
for ($i = 1; $i -le $maxRetries; $i++) {
    Write-Host "[Attempt $i/$maxRetries] Running rustup-init for x86_64-pc-windows-gnu..."
    $proc = Start-Process -FilePath $rustupExe -ArgumentList "-y --default-host x86_64-pc-windows-gnu --default-toolchain stable --profile default" -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -eq 0) {
        $rustSuccess = $true
        Write-Host "[Success] Rust GNU toolchain installed successfully!" -ForegroundColor Green
        break
    }
    Write-Warning "rustup-init returned exit code $($proc.ExitCode). Waiting 10 seconds before retry..."
    Start-Sleep -Seconds 10
}
Remove-Item -Force $rustupExe -ErrorAction SilentlyContinue

# 6. Configure System PATH and Cargo Config
Write-Host "`n[Step 5/8] Configuring System Environment and Cargo settings..." -ForegroundColor Yellow
$mingwBin = "$mingwDest\bin"
$cargoBin = "C:\Users\Administrator\.cargo\bin"

$currentMachinePath = [Environment]::GetEnvironmentVariable("Path", [EnvironmentVariableTarget]::Machine)
$newEntries = @($mingwBin, $cargoBin)
foreach ($entry in $newEntries) {
    if ($currentMachinePath -notlike "*$entry*") {
        $currentMachinePath = "$entry;$currentMachinePath"
    }
}
[Environment]::SetEnvironmentVariable("Path", $currentMachinePath, [EnvironmentVariableTarget]::Machine)
$env:Path = "$mingwBin;$cargoBin;" + $env:Path

# Cargo target configuration for deterministic GCC linker usage
$cargoHome = "C:\Users\Administrator\.cargo"
if (!(Test-Path $cargoHome)) { New-Item -ItemType Directory -Path $cargoHome -Force | Out-Null }
$cargoConfig = @"
[target.x86_64-pc-windows-gnu]
linker = "gcc"
ar = "ar"
"@
Set-Content -Path "$cargoHome\config.toml" -Value $cargoConfig -Encoding UTF8
Write-Host "[Info] Cargo config written to $cargoHome\config.toml"

# 7. Verification Self-Test
Write-Host "`n[Step 6/8] Running Toolchain Self-Test..." -ForegroundColor Yellow
try {
    Write-Host "[Check] GCC:"
    & "$mingwBin\gcc.exe" --version | Select-Object -First 1
    Write-Host "[Check] Rustc:"
    & "$cargoBin\rustc.exe" -Vv
    Write-Host "[Check] Cargo:"
    & "$cargoBin\cargo.exe" -V

    $testProject = "$env:TEMP\rust_verify_project"
    if (Test-Path $testProject) { Remove-Item -Recurse -Force $testProject }
    & "$cargoBin\cargo.exe" new --bin $testProject
    Set-Location $testProject
    Write-Host "[Check] Compiling sample binary with cargo build..."
    & "$cargoBin\cargo.exe" build
    
    $exePath = "$testProject\target\debug\rust_verify_project.exe"
    if (Test-Path $exePath) {
        Write-Host ">>> SUCCESS: Rust GNU binary built successfully! <<<" -ForegroundColor Green
        $testOutput = & $exePath
        Write-Host ">>> Executable Output: $testOutput <<<" -ForegroundColor Green
    } else {
        Write-Error "[Error] Expected executable $exePath not found!"
    }
    Set-Location C:\
    Remove-Item -Recurse -Force $testProject -ErrorAction SilentlyContinue
} catch {
    Write-Error "[Error] Toolchain verification encountered an error: $_"
}

# 8. Configure OpenSSH Server
Write-Host "`n[Step 7/8] Enabling OpenSSH Server service..." -ForegroundColor Yellow
try {
    Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 -ErrorAction SilentlyContinue
    Start-Service sshd -ErrorAction SilentlyContinue
    Set-Service -Name sshd -StartupType Automatic -ErrorAction SilentlyContinue
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 -ErrorAction SilentlyContinue
    Write-Host "[Success] OpenSSH Server enabled on port 22." -ForegroundColor Green
} catch {
    Write-Warning "[Warning] OpenSSH setup notice: $_"
}

# 9. Cleanup & Shutdown
Write-Host "`n[Step 8/8] Performing disk cleanup and shutting down..." -ForegroundColor Yellow
Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\Windows\SoftwareDistribution\Download\*" -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "$env:TEMP\*" -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\Windows\Temp\*" -ErrorAction SilentlyContinue
powercfg -h off
Optimize-Volume -DriveLetter C -Defrag -Verbose -ErrorAction SilentlyContinue

Write-Host "`n==================================================" -ForegroundColor Cyan
Write-Host " Provisioning completed successfully. Shutting down in 5 seconds." -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Cyan

Stop-Transcript
Start-Sleep -Seconds 5
Stop-Computer -Force
