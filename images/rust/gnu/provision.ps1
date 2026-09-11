# ==============================================================================
# Script: provision-rust-gnu.ps1
# Description: Automated Rust GNU toolchain provisioning
# Target: x86_64-pc-windows-gnu (w64devkit MinGW-w64 + Rustup)
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

Start-Transcript -Path "C:\provision-rust-gnu.log" -Append

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " [Step 1/6] Starting Rust GNU Provisioning (100% Offline Mode)..." -ForegroundColor Green
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
$cargoBin = "C:\Users\Administrator\.cargo\bin"

# 2. Deploy MinGW-w64 toolchain (w64devkit)
Write-Host "`n[Step 2/6] Deploying MinGW-w64 toolchain (w64devkit: gcc, ld, ar, make)..." -ForegroundColor Yellow
$mingwDest = "$toolsDir\w64devkit"
$tmpExe = "$env:TEMP\w64devkit.exe"

$localPayload = "$mediaDrive\w64devkit.exe"
if (!(Test-Path $localPayload) -or ((Get-Item $localPayload).Length -lt 10000000)) {
    throw "CRITICAL: Pre-staged w64devkit is missing or corrupted on payload media ($localPayload)!"
}

Write-Host "[Info] Using pre-staged w64devkit from payload media..."
Copy-Item -Path $localPayload -Destination $tmpExe -Force

Write-Host "[Info] Expanding w64devkit to $toolsDir..."
if (Test-Path $mingwDest) { Remove-Item -Recurse -Force $mingwDest -ErrorAction SilentlyContinue }
$proc = Start-Process -FilePath $tmpExe -ArgumentList "-y -o`"$toolsDir`"" -Wait -PassThru -NoNewWindow
Remove-Item -Force $tmpExe -ErrorAction SilentlyContinue

if ($proc.ExitCode -ne 0 -or !(Test-Path "$mingwDest\bin\gcc.exe")) {
    throw "CRITICAL: w64devkit extraction failed! ExitCode: $($proc.ExitCode), gcc.exe missing: $(!(Test-Path "$mingwDest\bin\gcc.exe"))"
}
Write-Host "[Success] MinGW-w64 toolchain deployed at $mingwDest" -ForegroundColor Green

# 3. Deploy Microsoft Visual C++ Redistributable (vc_redist.x64)
Write-Host "`n[Step 3/6] Deploying Microsoft Visual C++ Redistributable (x64)..." -ForegroundColor Yellow
$vcRedistExe = "$mediaDrive\vc_redist.x64.exe"
if (!(Test-Path $vcRedistExe) -or ((Get-Item $vcRedistExe).Length -lt 1000000)) {
    throw "CRITICAL: Pre-staged vc_redist.x64.exe missing or corrupted on payload media!"
}

Write-Host "[Info] Executing vc_redist.x64 installer silently..."
$vcProc = Start-Process -FilePath $vcRedistExe -ArgumentList "/install /quiet /norestart" -Wait -PassThru -NoNewWindow
if ($vcProc.ExitCode -ne 0 -and $vcProc.ExitCode -ne 3010) {
    throw "CRITICAL: vc_redist installer failed with exit code $($vcProc.ExitCode)!"
}
if (!(Test-Path "C:\Windows\System32\vcruntime140.dll")) {
    throw "CRITICAL: vcruntime140.dll missing from System32 after vc_redist installation!"
}
Write-Host "[Success] Visual C++ Redistributable installed successfully!" -ForegroundColor Green

# 4. Deploy Rust GNU Toolchain
Write-Host "`n[Step 4/6] Deploying Rust GNU toolchain (x86_64-pc-windows-gnu)..." -ForegroundColor Yellow
$rustDir = "C:\tools\rust"
if (Test-Path $rustDir) { Remove-Item -Recurse -Force $rustDir -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Path $rustDir -Force | Out-Null

if (Test-Path "$mediaDrive\rust-gnu.tar.gz") {
    Write-Host "[Info] Unpacking pre-staged Rust GNU archive ($mediaDrive\rust-gnu.tar.gz)..."
    & tar.exe -xzf "$mediaDrive\rust-gnu.tar.gz" -C $rustDir
} elseif (Test-Path "$mediaDrive\rust-gnu\bin\rustc.exe") {
    Write-Host "[Info] Copying pre-staged Rust GNU toolchain from $mediaDrive\rust-gnu..."
    Copy-Item -Path "$mediaDrive\rust-gnu\*" -Destination $rustDir -Recurse -Force
} else {
    throw "CRITICAL: Rust GNU toolchain payload not found on media!"
}

if (!(Test-Path "$rustDir\bin\rustc.exe")) {
    throw "CRITICAL: rustc.exe not found in $rustDir\bin after extraction!"
}
Write-Host "[Success] Rust GNU toolchain unpacked at $rustDir" -ForegroundColor Green

# Initialize offline rustup shims and link local toolchain
$rustupSrc = "$mediaDrive\rustup-init.exe"
if (Test-Path $rustupSrc) {
    Write-Host "[Info] Initializing offline rustup client..."
    $proc = Start-Process -FilePath $rustupSrc -ArgumentList "-y --default-host x86_64-pc-windows-gnu --default-toolchain none" -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ne 0) {
        Write-Warning "rustup-init returned exit code $($proc.ExitCode)"
    }
    if (Test-Path "$cargoBin\rustup.exe") {
        Write-Host "[Info] Linking local toolchain to rustup..."
        & "$cargoBin\rustup.exe" toolchain link gnu "$rustDir"
        & "$cargoBin\rustup.exe" toolchain link local "$rustDir"
        & "$cargoBin\rustup.exe" default gnu
    }
}

# 5. Configure System PATH, Cargo Config, and Deploy Ecosystem Tools
Write-Host "`n[Step 5/6] Configuring System Environment and Deploying Cargo Tools..." -ForegroundColor Yellow
$mingwBin = "$mingwDest\bin"
$rustBin = "$rustDir\bin"

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
$newEntries = @($mingwBin, $rustBin, $cargoBin)
foreach ($entry in $newEntries) {
    if (!$currentMachinePath.Contains($entry)) {
        $currentMachinePath = "$entry;$currentMachinePath"
    }
}
[Environment]::SetEnvironmentVariable("Path", $currentMachinePath, [EnvironmentVariableTarget]::Machine)
[Environment]::SetEnvironmentVariable("CARGO_HOME", $env:CARGO_HOME, [EnvironmentVariableTarget]::Machine)
[Environment]::SetEnvironmentVariable("RUSTUP_HOME", $env:RUSTUP_HOME, [EnvironmentVariableTarget]::Machine)
$env:Path = "$mingwBin;$rustBin;$cargoBin;" + $env:Path

$cargoHome = "C:\Users\Administrator\.cargo"
if (!(Test-Path $cargoHome)) { New-Item -ItemType Directory -Path $cargoHome -Force | Out-Null }
$cargoConfig = @"
[target.x86_64-pc-windows-gnu]
linker = "gcc"
ar = "ar"
"@
Set-Content -Path "$cargoHome\config.toml" -Value $cargoConfig -Encoding UTF8
Write-Host "[Info] Cargo config written to $cargoHome\config.toml"

# Deploy pre-staged Cargo tools from media
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
    Write-Host "[Check] GCC:"
    $gccOut = & "$mingwBin\gcc.exe" --version
    if ($LASTEXITCODE -ne 0 -or !$gccOut) { throw "gcc --version failed" }
    Write-Host ($gccOut | Select-Object -First 1)

    Write-Host "[Check] G++:"
    $gppOut = & "$mingwBin\g++.exe" --version
    if ($LASTEXITCODE -ne 0 -or !$gppOut) { throw "g++ --version failed" }
    Write-Host ($gppOut | Select-Object -First 1)

    Write-Host "[Check] GNU Make:"
    $makeOut = & "$mingwBin\make.exe" --version
    if ($LASTEXITCODE -ne 0 -or !$makeOut) { throw "make --version failed" }
    Write-Host ($makeOut | Select-Object -First 1)

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

    Write-Host "[Check] Visual C++ Redistributable:"
    if (!(Test-Path "C:\Windows\System32\vcruntime140.dll")) {
        throw "vcruntime140.dll missing from System32!"
    }
    Write-Host "vcruntime140.dll present in System32." -ForegroundColor Green

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

    $testProject = "$env:TEMP\rust_verify_project"
    if (Test-Path $testProject) { Remove-Item -Recurse -Force $testProject }
    & "$cargoBin\cargo.exe" new --bin $testProject
    Set-Location $testProject
    Write-Host "[Check] Compiling sample binary with cargo build..."
    & "$cargoBin\cargo.exe" build
    if ($LASTEXITCODE -ne 0) { throw "cargo build failed with exit code $LASTEXITCODE" }

    Write-Host "[Check] Running cargo clippy on sample project..."
    & "$cargoBin\cargo.exe" clippy
    if ($LASTEXITCODE -ne 0) { throw "cargo clippy failed with exit code $LASTEXITCODE" }
    
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

    # C compiler verification (gcc)
    $cTest = "$env:TEMP\test_c.c"
    $cExe = "$env:TEMP\test_c.exe"
    Set-Content -Path $cTest -Value @"
#include <stdio.h>
int main() {
    printf("HELLO_FROM_GCC_COMPILER\n");
    return 0;
}
"@ -Encoding ASCII
    & "$mingwBin\gcc.exe" $cTest -o $cExe
    if ($LASTEXITCODE -ne 0 -or !(Test-Path $cExe)) { throw "gcc compilation failed!" }
    $cOut = & $cExe
    Remove-Item -Force $cTest, $cExe -ErrorAction SilentlyContinue
    if (!$cOut.Contains("HELLO_FROM_GCC_COMPILER")) { throw "gcc execution output mismatch!" }
    Write-Host "[Check] C compilation and execution (gcc) succeeded." -ForegroundColor Green

    # C++ compiler verification (g++)
    $cppTest = "$env:TEMP\test_cpp.cpp"
    $cppExe = "$env:TEMP\test_cpp.exe"
    Set-Content -Path $cppTest -Value @"
#include <iostream>
int main() {
    std::cout << "HELLO_FROM_GPP_COMPILER" << std::endl;
    return 0;
}
"@ -Encoding ASCII
    & "$mingwBin\g++.exe" $cppTest -o $cppExe
    if ($LASTEXITCODE -ne 0 -or !(Test-Path $cppExe)) { throw "g++ compilation failed!" }
    $cppOut = & $cppExe
    Remove-Item -Force $cppTest, $cppExe -ErrorAction SilentlyContinue
    if (!$cppOut.Contains("HELLO_FROM_GPP_COMPILER")) { throw "g++ execution output mismatch!" }
    Write-Host "[Check] C++ compilation and execution (g++) succeeded." -ForegroundColor Green

    # Cargo install verification
    $installProject = "$env:TEMP\cargo_install_test"
    if (Test-Path $installProject) { Remove-Item -Recurse -Force $installProject }
    & "$cargoBin\cargo.exe" new --bin $installProject
    Set-Location $installProject
    & "$cargoBin\cargo.exe" install --debug --path .
    if ($LASTEXITCODE -ne 0) { throw "cargo install failed!" }
    Set-Location C:\
    $installedBin = "$cargoBin\cargo_install_test.exe"
    if (!(Test-Path $installedBin)) { throw "cargo installed binary not found in PATH!" }
    $instOut = & $installedBin
    & "$cargoBin\cargo.exe" uninstall cargo_install_test
    Remove-Item -Recurse -Force $installProject -ErrorAction SilentlyContinue
    if (!$instOut.Contains("Hello, world!")) { throw "cargo install binary output mismatch!" }
    Write-Host "[Check] Cargo install & run succeeded." -ForegroundColor Green
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
