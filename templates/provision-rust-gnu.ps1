# ==============================================================================
# Script: provision-rust-gnu.ps1
# Description: Automated Rust GNU toolchain provisioning
# Target: x86_64-pc-windows-gnu (w64devkit MinGW-w64 + Rustup)
# ==============================================================================
$ErrorActionPreference = "Continue"

# Prevent concurrent execution across SYSTEM and Administrator sessions
$global:mutex = New-Object System.Threading.Mutex($false, "Global\ImageProvisionExecutionMutex")
if (!$global:mutex.WaitOne(500, $false)) {
    Write-Host "[Mutex] Another provisioning runner is already executing. Terminating secondary process tree."
    $parent = (Get-WmiObject Win32_Process -Filter "ProcessId = $PID").ParentProcessId
    if ($parent) { Stop-Process -Id $parent -Force -ErrorAction SilentlyContinue }
    Stop-Process -Id $PID -Force
    exit 0
}

# Cleanup startup triggers to avoid subsequent invocations
reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" /v "ImageProvisionRunner" /f 2>$null
Unregister-ScheduledTask -TaskName "ImageProvisionRunner" -Confirm:$false -ErrorAction SilentlyContinue

Start-Transcript -Path "C:\provision-rust-gnu.log" -Append

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " [Step 1/5] Starting Rust GNU Provisioning..." -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Cyan

# 1. Locate payload media drive
$mediaDrive = $PSScriptRoot
if (!$mediaDrive -or !(Test-Path "$mediaDrive\child-provision.ps1")) {
    $vol = Get-Volume | Where-Object { 
        $dl = $_.DriveLetter
        if ($dl) { Test-Path "$($dl):\child-provision.ps1" } else { $false }
    } | Select-Object -First 1
    if ($vol) { $mediaDrive = "$($vol.DriveLetter):" }
}
Write-Host "[Info] Payload media found at drive: $mediaDrive"

$toolsDir = "C:\tools"
if (!(Test-Path $toolsDir)) { New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null }

$env:TEMP = "C:\Windows\Temp"
$env:TMP = "C:\Windows\Temp"
$env:CARGO_HOME = "C:\Users\Administrator\.cargo"
$env:RUSTUP_HOME = "C:\Users\Administrator\.rustup"

# 2. Extract or install w64devkit (MinGW-w64 GCC toolchain)
Write-Host "`n[Step 2/5] Deploying MinGW-w64 toolchain (w64devkit: gcc, ld, ar, make)..." -ForegroundColor Yellow
$mingwDest = "$toolsDir\w64devkit"
$localDevkitSfx = "$mediaDrive\packages\w64devkit-x64-2.9.1.7z.exe"
$localDevkitZip = "$mediaDrive\packages\w64devkit.zip"

if (Test-Path $localDevkitSfx) {
    Write-Host "[Info] Extracting w64devkit from local SFX archive: $localDevkitSfx..."
    $proc = Start-Process -FilePath $localDevkitSfx -ArgumentList "-y -aoa -o`"$toolsDir`"" -Wait -PassThru -NoNewWindow
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

# 3. Install Rustup and x86_64-pc-windows-gnu toolchain
Write-Host "`n[Step 3/5] Installing Rust GNU toolchain (x86_64-pc-windows-gnu)..." -ForegroundColor Yellow
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

if (!$rustSuccess) {
    throw "Failed to install Rust GNU toolchain after $maxRetries attempts."
}

# 4. Configure System PATH and Cargo Config
Write-Host "`n[Step 4/5] Configuring System Environment and Cargo settings..." -ForegroundColor Yellow
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

$cargoHome = "C:\Users\Administrator\.cargo"
if (!(Test-Path $cargoHome)) { New-Item -ItemType Directory -Path $cargoHome -Force | Out-Null }
$cargoConfig = @"
[target.x86_64-pc-windows-gnu]
linker = "gcc"
ar = "ar"
"@
Set-Content -Path "$cargoHome\config.toml" -Value $cargoConfig -Encoding UTF8
Write-Host "[Info] Cargo config written to $cargoHome\config.toml"

# 5. Verification Self-Test
Write-Host "`n[Step 5/5] Running Toolchain Self-Test..." -ForegroundColor Yellow
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
        throw "Expected executable $exePath not found!"
    }
    Set-Location C:\
    Remove-Item -Recurse -Force $testProject -ErrorAction SilentlyContinue
} catch {
    throw "Toolchain verification failed: $_"
}

# Cleanup
Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\Windows\SoftwareDistribution\Download\*" -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "$env:TEMP\*" -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\Windows\Temp\*" -ErrorAction SilentlyContinue
Optimize-Volume -DriveLetter C -Defrag -Verbose -ErrorAction SilentlyContinue

Write-Host "`n[Success] Rust GNU provisioning completed successfully!" -ForegroundColor Green
Stop-Transcript
exit 0
