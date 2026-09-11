# ==============================================================================
# Script: provision-rust-msvc.ps1
# Description: Automated Rust MSVC toolchain provisioning
# Target: x86_64-pc-windows-msvc (Visual Studio 2022 Build Tools + Rustup)
# ==============================================================================
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

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
Write-Host " [Step 1/6] Starting Rust MSVC Provisioning (100% Offline Mode)..." -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Cyan

# 1. Locate payload media drive and offline VS layout drive
$mediaDrive = $PSScriptRoot
if (!$mediaDrive -or !(Test-Path "$mediaDrive\child-provision.ps1")) {
    $vol = Get-Volume | Where-Object { 
        $dl = $_.DriveLetter
        if ($dl) { Test-Path "$($dl):\child-provision.ps1" } else { $false }
    } | Select-Object -First 1
    if ($vol) { $mediaDrive = "$($vol.DriveLetter):" }
}
Write-Host "[Info] Payload media found at drive: $mediaDrive"

$layoutDrive = $env:VS_LAYOUT_DRIVE
if (!$layoutDrive -or !(Test-Path "$layoutDrive\vs_BuildTools.exe" -or Test-Path "$layoutDrive\vs_setup.exe")) {
    # Ensure all secondary disks are online
    Get-Disk | Where-Object { $_.Number -ne 0 } | ForEach-Object {
        Set-Disk -Number $_.Number -IsOffline $false -ErrorAction SilentlyContinue
    }
    $vol = Get-Volume | Where-Object { 
        ($_.FileSystemLabel -eq 'VS_LAYOUT') -or (Test-Path "$($_.DriveLetter):\vs_BuildTools.exe") -or (Test-Path "$($_.DriveLetter):\vs_setup.exe")
    } | Select-Object -First 1
    if ($vol) { $layoutDrive = "$($vol.DriveLetter):" }
}

if (!$layoutDrive) {
    throw "CRITICAL: Offline VS layout disk not found on any drive!"
}
Write-Host "[Info] Offline VS layout disk found at: $layoutDrive" -ForegroundColor Green

$toolsDir = "C:\tools"
if (!(Test-Path $toolsDir)) { New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null }

# Ensure working temporary & cargo environment
$env:TEMP = "C:\Windows\Temp"
$env:TMP = "C:\Windows\Temp"
$env:CARGO_HOME = "C:\Users\Administrator\.cargo"
$env:RUSTUP_HOME = "C:\Users\Administrator\.rustup"
$cargoBin = "C:\Users\Administrator\.cargo\bin"

# 2. Deploy Visual Studio Build Tools 2022 from Offline Layout
Write-Host "`n[Step 2/6] Deploying Visual Studio 2022 Build Tools from Offline Layout..." -ForegroundColor Yellow

# Pre-import layout certificates and staged offline certificates to avoid offline trust issues
$certSearchPaths = @(
    "$layoutDrive\certificates",
    "$mediaDrive\certificates",
    "$PSScriptRoot\certificates",
    "C:\runner\certificates"
)

Get-PSDrive -PSProvider FileSystem | ForEach-Object {
    $c = Join-Path $_.Root "certificates"
    if (Test-Path $c) { $certSearchPaths += $c }
}
$certSearchPaths = $certSearchPaths | Select-Object -Unique

Write-Host "[Info] Importing Microsoft root and intermediate certificates for offline signature validation..."
foreach ($cDir in $certSearchPaths) {
    if (Test-Path $cDir) {
        Write-Host "  [Certs] Checking directory: $cDir"
        Get-ChildItem -Path $cDir -Include "*.cer","*.crt" -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            Write-Host "    -> Installing certificate: $($_.Name)"
            certutil.exe -addstore -f "Root" $_.FullName | Out-Null
            certutil.exe -addstore -f "CA" $_.FullName | Out-Null
            certutil.exe -addstore -f "TrustedPublisher" $_.FullName | Out-Null
            certutil.exe -addstore -f "AuthRoot" $_.FullName | Out-Null
        }
    }
}

$vsInstaller = if (Test-Path "$layoutDrive\vs_BuildTools.exe") {
    "$layoutDrive\vs_BuildTools.exe"
} elseif (Test-Path "$layoutDrive\vs_setup.exe") {
    "$layoutDrive\vs_setup.exe"
} else {
    throw "CRITICAL: Neither vs_BuildTools.exe nor vs_setup.exe found in $layoutDrive!"
}

Write-Host "[Info] Running Visual Studio Build Tools offline non-interactive installation..."
$vsArgs = @(
    "--quiet",
    "--wait",
    "--norestart",
    "--nocache",
    "--noWeb",
    "--noUpdateInstaller",
    "--installPath", "C:\BuildTools",
    "--add", "Microsoft.VisualStudio.Workload.VCTools",
    "--add", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
    "--add", "Microsoft.VisualStudio.Component.Windows11SDK.26100",
    "--add", "Microsoft.Component.VC.Runtime.UCRTSDK"
)

Write-Host "[Info] Launching installer: $vsInstaller $($vsArgs -join ' ')"
$proc = Start-Process -FilePath $vsInstaller -ArgumentList $vsArgs -Wait -PassThru -NoNewWindow
$exitCode = $proc.ExitCode
Write-Host "[Info] vs_BuildTools process exited with code $exitCode"

# Wait for background services to finalize
$childProcs = Get-Process -Name "vs_installer", "vs_installerservice", "setup" -ErrorAction SilentlyContinue
while ($childProcs) {
    Write-Host "[VS-Installer] Waiting for installer background services to finalize..."
    Start-Sleep -Seconds 5
    $childProcs = Get-Process -Name "vs_installer", "vs_installerservice", "setup" -ErrorAction SilentlyContinue
}

if ($exitCode -ne 0 -and $exitCode -ne 3010) {
    throw "Visual Studio Build Tools offline installation failed with exit code $exitCode"
}
Write-Host "[Success] Visual Studio Build Tools installed successfully!" -ForegroundColor Green

# 3. Deploy Rust MSVC Toolchain
Write-Host "`n[Step 3/6] Deploying Rust MSVC toolchain (x86_64-pc-windows-msvc)..." -ForegroundColor Yellow
$rustDir = "C:\tools\rust"
if (Test-Path $rustDir) { Remove-Item -Recurse -Force $rustDir -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Path $rustDir -Force | Out-Null

if (Test-Path "$mediaDrive\rust-msvc.tar.gz") {
    Write-Host "[Info] Unpacking pre-staged Rust MSVC archive ($mediaDrive\rust-msvc.tar.gz)..."
    & tar.exe -xzf "$mediaDrive\rust-msvc.tar.gz" -C $rustDir
} elseif (Test-Path "$mediaDrive\rust-msvc\bin\rustc.exe") {
    Write-Host "[Info] Copying pre-staged Rust MSVC toolchain from $mediaDrive\rust-msvc..."
    Copy-Item -Path "$mediaDrive\rust-msvc\*" -Destination $rustDir -Recurse -Force
} else {
    throw "CRITICAL: Rust MSVC toolchain payload not found on media!"
}

if (!(Test-Path "$rustDir\bin\rustc.exe")) {
    throw "CRITICAL: rustc.exe not found in $rustDir\bin after extraction!"
}
Write-Host "[Success] Rust MSVC toolchain unpacked at $rustDir" -ForegroundColor Green

# Initialize offline rustup client and link local toolchain
$rustupSrc = "$mediaDrive\rustup-init.exe"
if (Test-Path $rustupSrc) {
    Write-Host "[Info] Initializing offline rustup client..."
    $proc = Start-Process -FilePath $rustupSrc -ArgumentList "-y --default-host x86_64-pc-windows-msvc --default-toolchain none" -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ne 0) {
        Write-Warning "rustup-init returned exit code $($proc.ExitCode)"
    }
    if (Test-Path "$cargoBin\rustup.exe") {
        Write-Host "[Info] Linking local toolchain to rustup..."
        & "$cargoBin\rustup.exe" toolchain link msvc "$rustDir"
        & "$cargoBin\rustup.exe" toolchain link local "$rustDir"
        & "$cargoBin\rustup.exe" default msvc
    }
}

# 4. Configure System PATH and MSVC Environment
Write-Host "`n[Step 4/6] Configuring System Environment..." -ForegroundColor Yellow
$rustBin = "$rustDir\bin"
$vcvars64 = "C:\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if (Test-Path $vcvars64) {
    Write-Host "[Info] Persisting MSVC 64-bit environment from vcvars64.bat..."
    $envVars = cmd.exe /c "call `"$vcvars64`" && set"
    $targetVars = @("INCLUDE", "LIB", "LIBPATH", "WindowsSdkDir", "WindowsSDKVersion", "UniversalCRTSdkDir", "UCRTVersion")
    foreach ($line in $envVars) {
        $eqIdx = $line.IndexOf('=')
        if ($eqIdx -gt 0) {
            $varName = $line.Substring(0, $eqIdx)
            $varVal = $line.Substring($eqIdx + 1)
            if ($targetVars -contains $varName) {
                [Environment]::SetEnvironmentVariable($varName, $varVal, [EnvironmentVariableTarget]::Machine)
                [System.Environment]::SetEnvironmentVariable($varName, $varVal, "Process")
                Set-Item -Path "env:$varName" -Value $varVal -ErrorAction SilentlyContinue
            }
        }
    }
}
$currentMachinePath = [Environment]::GetEnvironmentVariable("Path", [EnvironmentVariableTarget]::Machine)
$installerDir = "C:\Program Files (x86)\Microsoft Visual Studio\Installer"
$newEntries = @($rustBin, $cargoBin, $installerDir)
foreach ($entry in $newEntries) {
    if (!$currentMachinePath.Contains($entry)) {
        $currentMachinePath = "$entry;$currentMachinePath"
    }
}
[Environment]::SetEnvironmentVariable("Path", $currentMachinePath, [EnvironmentVariableTarget]::Machine)
[Environment]::SetEnvironmentVariable("CARGO_HOME", $env:CARGO_HOME, [EnvironmentVariableTarget]::Machine)
[Environment]::SetEnvironmentVariable("RUSTUP_HOME", $env:RUSTUP_HOME, [EnvironmentVariableTarget]::Machine)
$env:Path = "$rustBin;$cargoBin;$installerDir;" + $env:Path

# 5. Deploy Pre-staged Cargo Ecosystem Tools
Write-Host "`n[Step 5/6] Deploying Pre-staged Cargo Ecosystem Tools..." -ForegroundColor Yellow
$cargoToolsMedia = "$mediaDrive\cargo-tools"
if (Test-Path $cargoToolsMedia) {
    Write-Host "[Info] Deploying pre-staged Cargo tools from $cargoToolsMedia..."
    if (!(Test-Path $cargoBin)) { New-Item -ItemType Directory -Path $cargoBin -Force | Out-Null }
    Copy-Item -Path "$cargoToolsMedia\*.exe" -Destination $cargoBin -Force
    Write-Host "[Success] Pre-staged Cargo tools deployed to $cargoBin." -ForegroundColor Green
} else {
    throw "CRITICAL: Pre-staged cargo-tools directory missing from payload media!"
}
$binstallExe = "$cargoBin\cargo-binstall.exe"

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
            $eqIdx = $_.IndexOf('=')
            if ($eqIdx -gt 0) {
                $vName = $_.Substring(0, $eqIdx)
                $vVal = $_.Substring($eqIdx + 1)
                [System.Environment]::SetEnvironmentVariable($vName, $vVal, "Process")
                Set-Item -Path "env:$vName" -Value $vVal -ErrorAction SilentlyContinue
            }
        }
    }

    Write-Host "[Check] Rustc:"
    $rustcOut = & "$cargoBin\rustc.exe" -Vv
    if ($LASTEXITCODE -ne 0 -or !$rustcOut) { throw "rustc -Vv failed" }
    Write-Host ($rustcOut | Select-Object -First 1)

    Write-Host "[Check] Cargo:"
    $cargoOut = & "$cargoBin\cargo.exe" -V
    if ($LASTEXITCODE -ne 0 -or !$cargoOut) { throw "cargo -V failed" }
    Write-Host $cargoOut

    Write-Host "[Check] Cargo Clippy & Clippy Driver:"
    $clippyOut = & "$cargoBin\cargo.exe" clippy --version
    if ($LASTEXITCODE -ne 0 -or !$clippyOut) { throw "cargo clippy --version failed" }
    Write-Host $clippyOut
    $clippyDriverOut = & "$cargoBin\clippy-driver.exe" --version
    if ($LASTEXITCODE -ne 0 -or !$clippyDriverOut) { throw "clippy-driver --version failed" }
    Write-Host $clippyDriverOut

    Write-Host "[Check] Cargo Fmt & Rustfmt:"
    $fmtOut = & "$cargoBin\cargo.exe" fmt --version
    if ($LASTEXITCODE -ne 0 -or !$fmtOut) { throw "cargo fmt --version failed" }
    Write-Host $fmtOut
    $rustfmtOut = & "$cargoBin\rustfmt.exe" --version
    if ($LASTEXITCODE -ne 0 -or !$rustfmtOut) { throw "rustfmt --version failed" }
    Write-Host $rustfmtOut

    Write-Host "[Check] cargo-binstall:"
    & $binstallExe -V
    if ($LASTEXITCODE -ne 0) { throw "cargo-binstall -V failed" }

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
    if ($LASTEXITCODE -ne 0) { throw "cargo build failed with exit code $LASTEXITCODE" }

    Write-Host "[Check] Running cargo clippy on sample project..."
    & "$cargoBin\cargo.exe" clippy
    if ($LASTEXITCODE -ne 0) { throw "cargo clippy failed with exit code $LASTEXITCODE" }
    
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

    # MSVC C/C++ compiler verification (cl.exe)
    $cppTest = "$env:TEMP\test_msvc.cpp"
    $cppExe = "$env:TEMP\test_msvc.exe"
    $cppObj = "$env:TEMP\test_msvc.obj"
    Set-Content -Path $cppTest -Value @"
#include <iostream>
int main() {
    std::cout << "HELLO_FROM_MSVC_COMPILER" << std::endl;
    return 0;
}
"@ -Encoding ASCII
    $vcvars = "C:\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
    if (Test-Path $vcvars) {
        cmd.exe /c "call `"$vcvars`" && cl.exe /nologo /EHsc `"$cppTest`" /Fe:`"$cppExe`" /Fo:`"$cppObj`""
    } else {
        cmd.exe /c "call `"$vsDevCmd`" -arch=x64 && cl.exe /nologo /EHsc `"$cppTest`" /Fe:`"$cppExe`" /Fo:`"$cppObj`""
    }
    if ($LASTEXITCODE -ne 0 -or !(Test-Path $cppExe)) { throw "cl.exe compilation failed with exit code $LASTEXITCODE!" }
    $cppOut = & $cppExe
    Remove-Item -Force $cppTest, $cppExe, $cppObj -ErrorAction SilentlyContinue
    if (!$cppOut.Contains("HELLO_FROM_MSVC_COMPILER")) { throw "MSVC binary output mismatch!" }
    Write-Host "[Check] C++ compilation and execution (cl.exe) succeeded." -ForegroundColor Green

    # Cargo install verification
    $installProject = "$env:TEMP\cargo_install_msvc_test"
    if (Test-Path $installProject) { Remove-Item -Recurse -Force $installProject }
    & "$cargoBin\cargo.exe" new --bin $installProject
    Set-Location $installProject
    & "$cargoBin\cargo.exe" install --debug --path .
    if ($LASTEXITCODE -ne 0) { throw "cargo install failed!" }
    Set-Location C:\
    $installedBin = "$cargoBin\cargo_install_msvc_test.exe"
    if (!(Test-Path $installedBin)) { throw "cargo installed binary not found in PATH!" }
    $instOut = & $installedBin
    & "$cargoBin\cargo.exe" uninstall cargo_install_msvc_test
    Remove-Item -Recurse -Force $installProject -ErrorAction SilentlyContinue
    if (!$instOut.Contains("Hello, world!")) { throw "cargo install binary output mismatch!" }
    Write-Host "[Check] Cargo install & run succeeded." -ForegroundColor Green
} catch {
    Write-Host "[CRITICAL ERROR] Toolchain verification failed: $_" -ForegroundColor Red
    Stop-Transcript
    exit 1
}

# Cleanup
Get-Process | Where-Object { 
    $p = $_.ProcessName
    ($p -eq 'vctip') -or ($p -eq 'BackgroundDownload') -or ($p.StartsWith('ServiceHub'))
} | Stop-Process -Force -ErrorAction SilentlyContinue

Remove-Item -Recurse -Force "C:\ProgramData\Package Cache\*" -ErrorAction SilentlyContinue
Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\Windows\SoftwareDistribution\Download\*" -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "$env:TEMP\*" -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\Windows\Temp\*" -ErrorAction SilentlyContinue
Optimize-Volume -DriveLetter C -Defrag -Verbose -ErrorAction SilentlyContinue

Get-Process | Where-Object { 
    $p = $_.ProcessName
    ($p -eq 'vctip') -or ($p -eq 'BackgroundDownload') -or ($p.StartsWith('ServiceHub'))
} | Stop-Process -Force -ErrorAction SilentlyContinue

Write-Host "`n[Success] Rust MSVC provisioning completed successfully!" -ForegroundColor Green
Stop-Transcript
exit 0
