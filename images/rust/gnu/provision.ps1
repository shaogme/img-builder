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
Write-Host " [Step 1/6] Starting Rust GNU Provisioning..." -ForegroundColor Green
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
Write-Host "`n[Step 2/6] Deploying MinGW-w64 toolchain (w64devkit: gcc, ld, ar, make)..." -ForegroundColor Yellow
$mingwDest = "$toolsDir\w64devkit"
Write-Host "[Info] Downloading latest w64devkit from GitHub..."
$url = "https://github.com/skeeto/w64devkit/releases/latest/download/w64devkit.zip"
$tmpZip = "$env:TEMP\w64devkit.zip"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri $url -OutFile $tmpZip -UseBasicParsing
Write-Host "[Info] Expanding w64devkit.zip..."
Expand-Archive -Path $tmpZip -DestinationPath $toolsDir -Force
Remove-Item -Force $tmpZip -ErrorAction SilentlyContinue

# 3. Deploy Microsoft Visual C++ Redistributable (vc_redist.x64)
Write-Host "`n[Step 3/6] Deploying Microsoft Visual C++ Redistributable (x64)..." -ForegroundColor Yellow
$vcRedistExe = "$env:TEMP\vc_redist.x64.exe"
Write-Host "[Info] Downloading latest vc_redist.x64.exe from Microsoft..."
Invoke-WebRequest -Uri "https://aka.ms/vs/17/release/vc_redist.x64.exe" -OutFile $vcRedistExe -UseBasicParsing

if (Test-Path $vcRedistExe) {
    Write-Host "[Info] Executing vc_redist.x64 installer silently..."
    $vcProc = Start-Process -FilePath $vcRedistExe -ArgumentList "/install /quiet /norestart" -Wait -PassThru -NoNewWindow
    if ($vcProc.ExitCode -eq 0 -or $vcProc.ExitCode -eq 3010) {
        Write-Host "[Success] Visual C++ Redistributable installed successfully (exit code $($vcProc.ExitCode))" -ForegroundColor Green
    } else {
        Write-Warning "vc_redist installer exited with code $($vcProc.ExitCode)"
    }
    Remove-Item -Force $vcRedistExe -ErrorAction SilentlyContinue
}

# 4. Install Rustup and x86_64-pc-windows-gnu toolchain
Write-Host "`n[Step 4/6] Installing Rust GNU toolchain (x86_64-pc-windows-gnu)..." -ForegroundColor Yellow
$rustupExe = "$env:TEMP\rustup-init.exe"
Write-Host "[Info] Downloading latest rustup-init.exe..."
Invoke-WebRequest -Uri "https://win.rustup.rs/x86_64" -OutFile $rustupExe -UseBasicParsing

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

# 5. Configure System PATH, Cargo Config, and Deploy cargo-binstall & Ecosystem Tools
Write-Host "`n[Step 5/6] Configuring System Environment and Deploying cargo-binstall..." -ForegroundColor Yellow
$mingwBin = "$mingwDest\bin"
$cargoBin = "C:\Users\Administrator\.cargo\bin"

# Ensure libgcc_eh.a exists for rustc MinGW compatibility
$gccLibDir = Get-ChildItem -Path "$mingwDest\lib\gcc\x86_64-w64-mingw32" -Directory | Select-Object -First 1
if ($gccLibDir) {
    $libgcc = "$($gccLibDir.FullName)\libgcc.a"
    $libgccEh = "$($gccLibDir.FullName)\libgcc_eh.a"
    if ((Test-Path $libgcc) -and !(Test-Path $libgccEh)) {
        Copy-Item -Path $libgcc -Destination $libgccEh -Force
        Write-Host "[Info] Created $libgccEh for rustc MinGW compatibility"
    }
}

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

# Deploy cargo-binstall
Write-Host "`n[Info] Downloading latest cargo-binstall from GitHub..." -ForegroundColor Yellow
$binstallExe = "$cargoBin\cargo-binstall.exe"
$tmpZip = "$env:TEMP\cargo-binstall.zip"
Invoke-WebRequest -Uri "https://github.com/cargo-bins/cargo-binstall/releases/latest/download/cargo-binstall-x86_64-pc-windows-msvc.zip" -OutFile $tmpZip -UseBasicParsing
Expand-Archive -Path $tmpZip -DestinationPath $cargoBin -Force
Remove-Item -Force $tmpZip -ErrorAction SilentlyContinue

if (!(Test-Path $binstallExe)) {
    throw "cargo-binstall.exe failed to deploy to $cargoBin!"
}
Write-Host "[Success] cargo-binstall deployed at $binstallExe" -ForegroundColor Green

# Install Cargo tools using cargo-binstall
$binstallTools = @(
    "sccache",
    "cargo-nextest",
    "cargo-sweep",
    "cargo-geiger",
    "cargo-audit",
    "flamegraph",
    "samply",
    "cargo-show-asm",
    "cargo-expand",
    "cargo-bloat"
)

Write-Host "`n[Info] Installing tools using cargo-binstall: $($binstallTools -join ', ')..." -ForegroundColor Yellow
foreach ($tool in $binstallTools) {
    Write-Host "[Binstall] Installing $tool..."
    $installed = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $proc = Start-Process -FilePath $binstallExe -ArgumentList "--no-confirm --targets x86_64-pc-windows-msvc $tool" -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -eq 0) {
            $installed = $true
            Write-Host "[Success] $tool installed successfully." -ForegroundColor Green
            break
        }
        Write-Warning "Failed to install $tool (attempt $attempt/3, exit code $($proc.ExitCode)). Retrying in 5s..."
        Start-Sleep -Seconds 5
    }
    if (!$installed) {
        throw "Failed to install $tool via cargo-binstall after 3 attempts."
    }
}

# 6. Verification Self-Test
Write-Host "`n[Step 6/6] Running Toolchain Self-Test..." -ForegroundColor Yellow
try {
    Write-Host "[Check] GCC:"
    & "$mingwBin\gcc.exe" --version | Select-Object -First 1
    Write-Host "[Check] Rustc:"
    & "$cargoBin\rustc.exe" -Vv
    Write-Host "[Check] Cargo:"
    & "$cargoBin\cargo.exe" -V

    Write-Host "[Check] Visual C++ Redistributable:"
    if (Test-Path "C:\Windows\System32\vcruntime140.dll") {
        Write-Host "vcruntime140.dll present in System32." -ForegroundColor Green
    } else {
        throw "vcruntime140.dll missing from System32!"
    }

    Write-Host "[Check] cargo-binstall:"
    & $binstallExe -V

    Write-Host "[Check] Tools installed via cargo-binstall:"
    & "$cargoBin\sccache.exe" --version
    & "$cargoBin\cargo-nextest.exe" --version
    & "$cargoBin\cargo-sweep.exe" --version
    & "$cargoBin\cargo-geiger.exe" --version
    & "$cargoBin\cargo-audit.exe" --version
    & "$cargoBin\cargo-flamegraph.exe" --version
    & "$cargoBin\samply.exe" --version
    & "$cargoBin\cargo-asm.exe" --version
    & "$cargoBin\cargo-expand.exe" --version
    & "$cargoBin\cargo-bloat.exe" --version

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
