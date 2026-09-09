# ==============================================================================
# Script: provision-rust-msvc.ps1
# Description: Automated Rust MSVC toolchain provisioning
# Target: x86_64-pc-windows-msvc (Visual Studio 2022 Build Tools + Rustup)
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

Start-Transcript -Path "C:\provision-rust-msvc.log" -Append

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " [Step 1/6] Starting Rust MSVC Provisioning..." -ForegroundColor Green
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

# Ensure working temporary & cargo environment
$env:TEMP = "C:\Windows\Temp"
$env:TMP = "C:\Windows\Temp"
$env:CARGO_HOME = "C:\Users\Administrator\.cargo"
$env:RUSTUP_HOME = "C:\Users\Administrator\.rustup"

# Ensure network connectivity before proceeding
Write-Host "`n[Network] Waiting for network connectivity (DHCP / DNS)..." -ForegroundColor Yellow
for ($attempt = 1; $attempt -le 30; $attempt++) {
    try {
        $res = Invoke-WebRequest -Uri "https://aka.ms" -UseBasicParsing -TimeoutSec 5
        if ($res.StatusCode -eq 200 -or $res.StatusCode -eq 301 -or $res.StatusCode -eq 302) {
            Write-Host "[Success] Network is online and accessible!" -ForegroundColor Green
            break
        }
    } catch {
        Write-Host "[Wait] Waiting for network interface (attempt $attempt/30)..."
        Start-Sleep -Seconds 2
    }
}

# 2. Deploy Visual Studio Build Tools 2022
Write-Host "`n[Step 2/6] Deploying Visual Studio 2022 Build Tools (MSVC & Windows SDK)..." -ForegroundColor Yellow
$vsExe = "C:\Windows\Temp\vs_BuildTools.exe"
Write-Host "[Info] Downloading latest vs_BuildTools.exe from Microsoft..."
Invoke-WebRequest -Uri "https://aka.ms/vs/17/release/vs_BuildTools.exe" -OutFile $vsExe -UseBasicParsing

Write-Host "[Info] Running Visual Studio Build Tools non-interactive installation..."
$vsArgs = @(
    "--quiet",
    "--wait",
    "--norestart",
    "--nocache",
    "--noUpdateInstaller",
    "--installPath", "C:\BuildTools",
    "--add", "Microsoft.VisualStudio.Workload.VCTools",
    "--add", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
    "--add", "Microsoft.VisualStudio.Component.Windows11SDK.26100",
    "--add", "Microsoft.Component.VC.Runtime.UCRTSDK"
)

Write-Host "[Info] Launching installer with targeted MSVC components..."
$proc = Start-Process -FilePath $vsExe -ArgumentList $vsArgs -PassThru

# Monitor installer progress with live logging
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$lastMsg = ""
while (!$proc.HasExited) {
    Start-Sleep -Seconds 10
    $mins = [int]$sw.Elapsed.TotalMinutes
    $logFiles = Get-ChildItem -Path "C:\Windows\Temp\dd_*.log", "$env:USERPROFILE\AppData\Local\Temp\dd_*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
    if ($logFiles) {
        $recent = Get-Content -Path $logFiles[0].FullName -Tail 1 -ErrorAction SilentlyContinue | Out-String
        $trimmed = $recent.Trim()
        if ($trimmed -and $trimmed -ne $lastMsg) {
            $lastMsg = $trimmed
            Write-Host "[VS-Installer $mins min] $lastMsg"
        }
    } else {
        Write-Host "[VS-Installer $mins min] Downloading and configuring components..."
    }
}
$exitCode = $proc.ExitCode
Write-Host "[Info] vs_BuildTools bootstrapper process exited with code $exitCode"

# Wait for any child installer processes if still active
$childProcs = Get-Process -Name "vs_installer", "vs_installerservice", "setup" -ErrorAction SilentlyContinue
while ($childProcs) {
    Write-Host "[VS-Installer] Waiting for installer background services to finalize..."
    Start-Sleep -Seconds 10
    $childProcs = Get-Process -Name "vs_installer", "vs_installerservice", "setup" -ErrorAction SilentlyContinue
}

if ($exitCode -eq 0 -or $exitCode -eq 3010) {
    Write-Host "[Success] Visual Studio Build Tools installed successfully!" -ForegroundColor Green
} else {
    throw "Visual Studio Build Tools installation failed with exit code $exitCode"
}
Remove-Item -Force $vsExe -ErrorAction SilentlyContinue

# 3. Install Rustup and x86_64-pc-windows-msvc toolchain
Write-Host "`n[Step 3/6] Installing Rust MSVC toolchain (x86_64-pc-windows-msvc)..." -ForegroundColor Yellow
$rustupExe = "C:\Windows\Temp\rustup-init.exe"
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
    Write-Host "[Attempt $i/$maxRetries] Running rustup-init for x86_64-pc-windows-msvc..."
    $proc = Start-Process -FilePath $rustupExe -ArgumentList "-y --default-host x86_64-pc-windows-msvc --default-toolchain stable --profile default" -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -eq 0) {
        $rustSuccess = $true
        Write-Host "[Success] Rust MSVC toolchain installed successfully!" -ForegroundColor Green
        break
    }
    Write-Warning "rustup-init returned exit code $($proc.ExitCode). Waiting 10 seconds before retry..."
    Start-Sleep -Seconds 10
}
Remove-Item -Force $rustupExe -ErrorAction SilentlyContinue

if (!$rustSuccess) {
    throw "Failed to install Rust MSVC toolchain after $maxRetries attempts."
}

# 4. Configure System PATH and MSVC Environment
Write-Host "`n[Step 4/6] Configuring System Environment..." -ForegroundColor Yellow
$cargoBin = "C:\Users\Administrator\.cargo\bin"
$vcvars64 = "C:\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if (Test-Path $vcvars64) {
    Write-Host "[Info] Persisting MSVC 64-bit environment from vcvars64.bat..."
    $envVars = cmd.exe /c "call `"$vcvars64`" && set"
    foreach ($line in $envVars) {
        if ($line -match "^(INCLUDE|LIB|LIBPATH|WindowsSdkDir|WindowsSDKVersion|UniversalCRTSdkDir|UCRTVersion)=(.*)$") {
            [Environment]::SetEnvironmentVariable($matches[1], $matches[2], [EnvironmentVariableTarget]::Machine)
            [System.Environment]::SetEnvironmentVariable($matches[1], $matches[2], "Process")
        }
    }
}
$currentMachinePath = [Environment]::GetEnvironmentVariable("Path", [EnvironmentVariableTarget]::Machine)
if ($currentMachinePath -notlike "*$cargoBin*") {
    $currentMachinePath = "$cargoBin;$currentMachinePath"
    [Environment]::SetEnvironmentVariable("Path", $currentMachinePath, [EnvironmentVariableTarget]::Machine)
}
$env:Path = "$cargoBin;" + $env:Path

# 5. Deploy cargo-binstall and Cargo Ecosystem Tools
Write-Host "`n[Step 5/6] Downloading latest cargo-binstall from GitHub..." -ForegroundColor Yellow
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
    # Check vswhere and load VS Developer environment
    $vswhere = "C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        Write-Host "[Check] VS Installation detected via vswhere:"
        & $vswhere -latest -products * -property displayName
    } else {
        Write-Warning "[Warning] vswhere.exe not found at standard location."
    }

    $vsDevCmd = "C:\BuildTools\Common7\Tools\VsDevCmd.bat"
    if (Test-Path $vsDevCmd) {
        Write-Host "[Info] Initializing MSVC environment via VsDevCmd.bat (-arch=x64)..."
        cmd.exe /c "call `"$vsDevCmd`" -arch=x64 && set" | ForEach-Object {
            if ($_ -match "^([^=]+)=(.*)$") {
                [System.Environment]::SetEnvironmentVariable($matches[1], $matches[2], "Process")
            }
        }
    }

    Write-Host "[Check] Rustc:"
    & "$cargoBin\rustc.exe" -Vv
    Write-Host "[Check] Cargo:"
    & "$cargoBin\cargo.exe" -V

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

    $testProject = "$env:TEMP\rust_verify_msvc"
    if (Test-Path $testProject) { Remove-Item -Recurse -Force $testProject }
    & "$cargoBin\cargo.exe" new --bin $testProject
    Set-Location $testProject
    Write-Host "[Check] Compiling sample binary with cargo build (MSVC ABI)..."
    & "$cargoBin\cargo.exe" build
    
    $exePath = "$testProject\target\debug\rust_verify_msvc.exe"
    if (Test-Path $exePath) {
        Write-Host ">>> SUCCESS: Rust MSVC binary built successfully! <<<" -ForegroundColor Green
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
Get-Process | Where-Object { $_.ProcessName -match '^(vctip|BackgroundDownload|ServiceHub.*)$' } | Stop-Process -Force -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\ProgramData\Package Cache\*" -ErrorAction SilentlyContinue
Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\Windows\SoftwareDistribution\Download\*" -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "$env:TEMP\*" -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\Windows\Temp\*" -ErrorAction SilentlyContinue
Optimize-Volume -DriveLetter C -Defrag -Verbose -ErrorAction SilentlyContinue

Get-Process | Where-Object { $_.ProcessName -match '^(vctip|BackgroundDownload|ServiceHub.*)$' } | Stop-Process -Force -ErrorAction SilentlyContinue
Write-Host "`n[Success] Rust MSVC provisioning completed successfully!" -ForegroundColor Green
Stop-Transcript
exit 0
