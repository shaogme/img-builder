# ==============================================================================
# Script: download-layout.ps1
# Description: Visual Studio 2022 Build Tools Offline Layout Generator
# Target: Executed inside transient Base VM to populate vs_layout.qcow2
# ==============================================================================
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# Prevent concurrent execution across SYSTEM and Administrator sessions
$global:mutex = New-Object System.Threading.Mutex($false, "Global\ImageProvisionExecutionMutex")
$myParent = (Get-CimInstance Win32_Process -Filter "ProcessId = $PID").ParentProcessId

if (!$global:mutex.WaitOne(500, $false)) {
    Write-Host "[Mutex] Another provisioning runner is already executing. Terminating secondary process tree."
    if ($myParent) { Stop-Process -Id $myParent -Force -ErrorAction SilentlyContinue }
    Stop-Process -Id $PID -Force
    exit 0
}

# Cleanup startup triggers immediately to avoid concurrent invocations
reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" /v "ImageProvisionRunner" /f 2>$null
Unregister-ScheduledTask -TaskName "ImageProvisionRunner" -Confirm:$false -ErrorAction SilentlyContinue

# Terminate any other powershell processes running provision-runner to prevent duplicate triggers
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object {
    $_.ProcessId -ne $PID -and $_.ProcessId -ne $myParent -and $_.CommandLine -like "*provision-runner.ps1*"
} | ForEach-Object {
    Write-Host "[Mutex] Terminating secondary runner process $($_.ProcessId)..."
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
}

Start-Transcript -Path "C:\vs-layout-download.log" -Append

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " VS BuildTools Layout Downloader (Transient VM)" -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Cyan

# 1. Locate media drive containing bootstrapper
$mediaDrive = $PSScriptRoot
if (!$mediaDrive -or !(Test-Path "$mediaDrive\vs_BuildTools.exe")) {
    $vol = Get-Volume | Where-Object { 
        $dl = $_.DriveLetter
        if ($dl) { Test-Path "$($dl):\vs_BuildTools.exe" } else { $false }
    } | Select-Object -First 1
    if ($vol) { $mediaDrive = "$($vol.DriveLetter):" }
}
Write-Host "[Info] Media drive located at: $mediaDrive"

# 2. Locate unformatted secondary disk and initialize as NTFS (VS_LAYOUT)
Write-Host "[Disk] Scanning for layout storage drive..."
$layoutDrive = $null

# Ensure all non-system disks are online
Get-Disk | Where-Object { $_.Number -ne 0 } | ForEach-Object {
    Set-Disk -Number $_.Number -IsOffline $false -ErrorAction SilentlyContinue
    Set-Disk -Number $_.Number -IsReadOnly $false -ErrorAction SilentlyContinue
}

$existingVol = Get-Volume | Where-Object { $_.FileSystemLabel -eq "VS_LAYOUT" } | Select-Object -First 1
if ($existingVol) {
    $layoutDrive = "$($existingVol.DriveLetter):"
    Write-Host "[Disk] Found existing VS_LAYOUT volume at $layoutDrive"
} else {
    $rawDisk = Get-Disk | Where-Object { $_.PartitionStyle -eq 'RAW' } | Select-Object -First 1
    if ($rawDisk) {
        Write-Host "[Disk] Initializing RAW disk $($rawDisk.Number) with MBR..."
        Set-Disk -Number $rawDisk.Number -IsOffline $false -ErrorAction SilentlyContinue
        Set-Disk -Number $rawDisk.Number -IsReadOnly $false -ErrorAction SilentlyContinue
        Initialize-Disk -Number $rawDisk.Number -PartitionStyle MBR -PassThru | Out-Null
        $part = New-Partition -DiskNumber $rawDisk.Number -UseMaximumSize -AssignDriveLetter
        Format-Volume -Partition $part -FileSystem NTFS -NewFileSystemLabel "VS_LAYOUT" -Confirm:$false | Out-Null
        $layoutDrive = "$($part.DriveLetter):"
        Write-Host "[Disk] Formatted disk $($rawDisk.Number) as $layoutDrive (VS_LAYOUT)" -ForegroundColor Green
    }
}

if (!$layoutDrive) {
    throw "CRITICAL: Unable to locate or format VS_LAYOUT destination drive!"
}

# 3. Wait for network connectivity
Write-Host "`n[Network] Verifying internet access to Microsoft CDN..." -ForegroundColor Yellow
$netOk = $false
for ($i = 1; $i -le 30; $i++) {
    try {
        $res = Invoke-WebRequest -Uri "https://aka.ms" -UseBasicParsing -TimeoutSec 5
        if ($res.StatusCode -in @(200, 301, 302)) {
            $netOk = $true
            Write-Host "[Success] Internet access verified." -ForegroundColor Green
            break
        }
    } catch {
        Write-Host "[Wait] Waiting for network interface ($i/30)..."
        Start-Sleep -Seconds 2
    }
}
if (!$netOk) {
    throw "CRITICAL: Internet access unavailable in layout downloader VM!"
}

# 4. Copy bootstrapper locally
$vsExe = "C:\Windows\Temp\vs_BuildTools.exe"
Copy-Item "$mediaDrive\vs_BuildTools.exe" $vsExe -Force

try {
    # 5. Create offline layout on target drive
    Write-Host "`n[Download] Creating Visual Studio 2022 Build Tools offline layout..." -ForegroundColor Yellow
    $layoutArgs = @(
        "--layout", "$layoutDrive\",
        "--add", "Microsoft.VisualStudio.Workload.VCTools",
        "--add", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
        "--add", "Microsoft.VisualStudio.Component.Windows11SDK.26100",
        "--add", "Microsoft.Component.VC.Runtime.UCRTSDK",
        "--lang", "en-US",
        "--quiet",
        "--wait",
        "--norestart"
    )

    Write-Host "[Download] Executable: $vsExe"
    Write-Host "[Download] Arguments:  $($layoutArgs -join ' ')"

    $proc = Start-Process -FilePath $vsExe -ArgumentList $layoutArgs -PassThru

    Write-Host "[Download] Waiting for Visual Studio installer process to initialize..."
    for ($w = 1; $w -le 25; $w++) {
        $initProcs = Get-Process | Where-Object { 
            $n = $_.ProcessName
            ($n -like "vs_*") -or ($n -eq "setup") -or ($n -like "*installer*")
        }
        if ($initProcs) {
            $initNames = ($initProcs | Select-Object -ExpandProperty ProcessName -Unique) -join ', '
            Write-Host "[Download] Detected active installer process(es): [$initNames]"
            break
        }
        Start-Sleep -Seconds 2
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $noProcCount = 0

    while ($true) {
        Start-Sleep -Seconds 15
        $mins = [int]$sw.Elapsed.TotalMinutes
        
        $files = Get-ChildItem -Path "$layoutDrive\" -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum
        $mb = if ($files.Sum) { [math]::Round($files.Sum / 1MB, 1) } else { 0 }
        
        $activeProcs = Get-Process | Where-Object { 
            $n = $_.ProcessName
            ($n -like "vs_*") -or ($n -eq "setup") -or ($n -like "*installer*")
        }
        
        if ($activeProcs) {
            $noProcCount = 0
            $activeNames = ($activeProcs | Select-Object -ExpandProperty ProcessName -Unique) -join ', '
            Write-Host "[VS-Layout $mins min] Total downloaded: $mb MB ($($files.Count) files). Active: [$activeNames]..."
        } else {
            $noProcCount++
            Write-Host "[VS-Layout $mins min] No active installer processes detected (check $noProcCount/4)... Total downloaded: $mb MB ($($files.Count) files)"
            if ($noProcCount -ge 4) {
                Write-Host "[VS-Layout] All installer processes have completed."
                break
            }
        }
    }

    # Verify output in layout directory
    $finalFiles = Get-ChildItem -Path "$layoutDrive\" -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum
    $finalMB = if ($finalFiles.Sum) { [math]::Round($finalFiles.Sum / 1MB, 1) } else { 0 }
    Write-Host "[VS-Layout] Final downloaded size on $layoutDrive : $finalMB MB ($($finalFiles.Count) files)"

    if ($finalMB -lt 500) {
        throw "CRITICAL: VS layout size ($finalMB MB) is less than 500MB! Layout download failed."
    }

    $layoutBootstrapper = if (Test-Path "$layoutDrive\vs_BuildTools.exe") {
        "$layoutDrive\vs_BuildTools.exe"
    } elseif (Test-Path "$layoutDrive\vs_setup.exe") {
        "$layoutDrive\vs_setup.exe"
    } else {
        $null
    }

    if (!$layoutBootstrapper) {
        Write-Host "[Info] Copying bootstrapper to $layoutDrive\vs_BuildTools.exe..."
        Copy-Item $vsExe "$layoutDrive\vs_BuildTools.exe" -Force
    }

    Write-Host "==================================================" -ForegroundColor Green
    Write-Host " Visual Studio Layout Created Successfully on $layoutDrive ($finalMB MB)" -ForegroundColor Green
    Write-Host "==================================================" -ForegroundColor Green
}
finally {
    try { Stop-Transcript } catch { }
    Write-Host "[Logs] Preserving layout and installer logs to $layoutDrive\logs..."
    $destLogs = "$layoutDrive\logs"
    New-Item -ItemType Directory -Path $destLogs -Force | Out-Null
    Copy-Item -Path "C:\vs-layout-download.log" -Destination $destLogs -Force -ErrorAction SilentlyContinue
    Copy-Item -Path "C:\provision-runner.log" -Destination $destLogs -Force -ErrorAction SilentlyContinue

    $tempLocations = @(
        $env:TEMP,
        "C:\Windows\Temp",
        "C:\Users\Administrator\AppData\Local\Temp",
        "C:\Windows\System32\config\systemprofile\AppData\Local\Temp"
    )
    foreach ($tl in $tempLocations) {
        if (Test-Path $tl) {
            Get-ChildItem -Path $tl -Filter "dd_*.log" -Recurse -ErrorAction SilentlyContinue |
                Copy-Item -Destination $destLogs -Force -ErrorAction SilentlyContinue
        }
    }

    Remove-Item -Force $vsExe -ErrorAction SilentlyContinue
}

Start-Sleep -Seconds 5
Stop-Computer -Force
