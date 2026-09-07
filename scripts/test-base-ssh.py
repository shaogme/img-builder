#!/usr/bin/env python3
"""
Automated Test Suite for Windows Server 2025 Core Base Image (output/win2025-core.qcow2).
- Boots image with isolated transient CoW overlay in QEMU/KVM
- Connects via OpenSSH on port 2222 with Administrator credentials
- Runs comprehensive verification of OS, hardware, VirtIO drivers, services, runner, and shell I/O
- Shuts down VM gracefully and reports test summary
"""

import os
import sys
import time
import socket
import subprocess
import json
from pathlib import Path

WORKSPACE_DIR = Path("/workspace")
BUILD_DIR = WORKSPACE_DIR / "build"
OUTPUT_DIR = WORKSPACE_DIR / "output"
BASE_IMAGE = OUTPUT_DIR / "win2025-core.qcow2"
METADATA_FILE = OUTPUT_DIR / "win2025-core.json"

OVERLAY_IMAGE = BUILD_DIR / "test-base-overlay.qcow2"
MONITOR_SOCK = BUILD_DIR / "qemu-test-monitor.sock"
TEST_RESULTS_FILE = BUILD_DIR / "test-base-results.json"

SSH_HOST = "127.0.0.1"
SSH_PORT = 2222
SSH_USER = "Administrator"
SSH_PASS = "Admin1234!"
MEMORY_MB = "8192"
CPUS = "4"
VNC_PORT = "1"

def log(msg, level="INFO"):
    colors = {
        "INFO": "\033[1;34m[INFO]\033[0m",
        "STEP": "\033[1;36m==>\033[0m",
        "PASS": "\033[1;32m[PASS]\033[0m",
        "FAIL": "\033[1;31m[FAIL]\033[0m",
        "WARN": "\033[1;33m[WARN]\033[0m",
    }
    prefix = colors.get(level, f"[{level}]")
    print(f"{prefix} {msg}", flush=True)

def run_cmd(cmd, check=True):
    return subprocess.run(cmd, check=check, capture_output=True, text=True)

def ssh_exec(remote_command, timeout=35):
    ssh_cmd = [
        "sshpass", "-p", SSH_PASS,
        "ssh",
        "-p", str(SSH_PORT),
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", "LogLevel=ERROR",
        "-o", "ConnectTimeout=10",
        f"{SSH_USER}@{SSH_HOST}",
        remote_command
    ]
    try:
        proc = subprocess.run(ssh_cmd, capture_output=True, text=True, timeout=timeout)
        return proc.returncode, proc.stdout.strip(), proc.stderr.strip()
    except subprocess.TimeoutExpired:
        return -1, "", "SSH command timed out"

def wait_for_ssh(timeout_sec=120):
    log(f"Waiting for OpenSSH service on {SSH_HOST}:{SSH_PORT} (up to {timeout_sec}s)...", "INFO")
    start_time = time.time()
    
    while time.time() - start_time < timeout_sec:
        code, out, err = ssh_exec("echo SSH_AUTH_OK", timeout=8)
        if code == 0 and "SSH_AUTH_OK" in out:
            elapsed = int(time.time() - start_time)
            log(f"SSH authentication succeeded after {elapsed} seconds!", "PASS")
            return True, elapsed
        time.sleep(3)

    log("SSH authentication timed out!", "FAIL")
    return False, int(time.time() - start_time)

def main():
    print("=" * 70)
    print(" Windows Server 2025 Core Base Image OpenSSH & Functionality Test")
    print(f" Target Image: {BASE_IMAGE}")
    print("=" * 70)

    log("Validating prerequisites...", "STEP")
    if not BASE_IMAGE.is_file():
        log(f"Base image not found at {BASE_IMAGE}", "FAIL")
        sys.exit(1)

    BUILD_DIR.mkdir(parents=True, exist_ok=True)

    # 1. Create transient CoW overlay
    log("Creating isolated transient CoW overlay (protecting base image)...", "STEP")
    if OVERLAY_IMAGE.exists():
        OVERLAY_IMAGE.unlink()
    
    run_cmd([
        "qemu-img", "create", "-f", "qcow2",
        "-b", str(BASE_IMAGE.resolve()),
        "-F", "qcow2",
        str(OVERLAY_IMAGE.resolve())
    ])
    log(f"Transient overlay ready: {OVERLAY_IMAGE}", "INFO")

    # 2. Start QEMU
    if MONITOR_SOCK.exists():
        MONITOR_SOCK.unlink()

    qemu_cmd = [
        "qemu-system-x86_64",
        "-enable-kvm",
        "-m", MEMORY_MB,
        "-smp", CPUS,
        "-cpu", "host,hv_relaxed,hv_spinlocks=0x1fff,hv_vapic,hv_time",
        "-drive", f"file={OVERLAY_IMAGE},if=virtio,format=qcow2,cache=writeback",
        "-netdev", f"user,id=net0,hostfwd=tcp::{SSH_PORT}-:22",
        "-device", "virtio-net-pci,netdev=net0",
        "-vnc", f"127.0.0.1:{VNC_PORT}",
        "-display", "none",
        "-monitor", f"unix:{MONITOR_SOCK},server,nowait",
        "-boot", "order=c",
        "-no-reboot"
    ]

    log("Launching Windows Server 2025 Core VM with QEMU KVM...", "STEP")
    qemu_proc = subprocess.Popen(qemu_cmd)
    log(f"QEMU process started (PID: {qemu_proc.pid})", "INFO")

    test_results = []

    def record_test(name, success, details=""):
        test_results.append({
            "name": name,
            "passed": success,
            "details": details
        })
        if success:
            log(f"{name}: PASSED", "PASS")
        else:
            log(f"{name}: FAILED - {details}", "FAIL")

    try:
        ssh_ok, boot_time = wait_for_ssh(timeout_sec=120)
        if not ssh_ok:
            record_test("OpenSSH Connectivity", False, "Failed to connect within timeout")
            return 1
        record_test("OpenSSH Connectivity", True, f"Connected in {boot_time}s as {SSH_USER}@{SSH_HOST}:{SSH_PORT}")

        log("Executing System and Functional Test Cases via OpenSSH...", "STEP")

        # Test 1: OS Version and Edition
        log("Test 1: Verifying OS Name, Version, Build, and Architecture...", "INFO")
        code, out, err = ssh_exec('powershell -NoProfile -Command "Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber, OSArchitecture, OperatingSystemSKU | Format-List"')
        print("\n--- OS Info ---")
        print(out)
        print("----------------")
        os_ok = code == 0 and "26100" in out and "Windows Server 2025" in out
        record_test("OS Identity (Windows Server 2025 Core Build 26100)", os_ok, out)

        # Test 2: Current User and Administrator Privileges
        log("Test 2: Verifying Current User Identity and Administrator Privileges...", "INFO")
        code, out, err = ssh_exec('powershell -NoProfile -Command "Write-Output (whoami); Write-Output ((([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)))"')
        print("\n--- User Context ---")
        print(out)
        print("--------------------")
        user_ok = code == 0 and "administrator" in out.lower() and "True" in out
        record_test("User Identity & Admin Privileges", user_ok, out)

        # Test 3: Hardware Resources (CPU, Memory, Disk C:)
        log("Test 3: Checking Hardware Resource Allocation (CPU, RAM, Disk C:)...", "INFO")
        hw_cmd = 'powershell -NoProfile -Command "$os = Get-CimInstance Win32_OperatingSystem; $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1; $vol = Get-Volume -DriveLetter C; [PSCustomObject]@{ CPU_Model = $cpu.Name; Cores = $cpu.NumberOfCores; Logical_Processors = $cpu.NumberOfLogicalProcessors; Total_RAM_GB = [math]::round($os.TotalVisibleMemorySize/1MB, 2); Free_RAM_GB = [math]::round($os.FreePhysicalMemory/1MB, 2); Disk_C_Total_GB = [math]::round($vol.Size/1GB, 2); Disk_C_Free_GB = [math]::round($vol.SizeRemaining/1GB, 2); Disk_C_FileSystem = $vol.FileSystemType } | Format-List"'
        code, out, err = ssh_exec(hw_cmd)
        print("\n--- Hardware Resources ---")
        print(out)
        print("--------------------------")
        hw_ok = code == 0 and "Total_RAM_GB" in out and "Disk_C_Total_GB" in out
        record_test("Hardware Resources Allocation", hw_ok, out)

        # Test 4: VirtIO Drivers and Services (sshd, QEMU-GA)
        log("Test 4: Inspecting VirtIO Drivers & System Services (sshd, QEMU-GA)...", "INFO")
        virtio_cmd = 'powershell -NoProfile -Command "Write-Output \'=== VirtIO Devices ===\'; Get-PnpDevice | Where-Object { $_.FriendlyName -like \'*VirtIO*\' -or $_.FriendlyName -like \'*Red Hat*\' } | Select-Object FriendlyName, Status, Class | Format-Table -AutoSize | Out-String -Width 120; Write-Output \'=== System Services ===\'; Get-Service -Name sshd, QEMU-GA -ErrorAction SilentlyContinue | Select-Object Name, Status, StartType | Format-Table -AutoSize | Out-String -Width 120"'
        code, out, err = ssh_exec(virtio_cmd)
        print("\n--- VirtIO Devices & Services ---")
        print(out)
        print("---------------------------------")
        virtio_ok = code == 0 and "VirtIO" in out and "Running" in out
        record_test("VirtIO Drivers & System Services", virtio_ok, out)

        # Test 5: Provisioning Infrastructure
        log("Test 5: Checking Downstream Provisioning Runner & Scheduled Task...", "INFO")
        prov_cmd = 'powershell -NoProfile -Command "$task = Get-ScheduledTask -TaskName ImageProvisionRunner -ErrorAction SilentlyContinue; $scriptExists = Test-Path C:\\tools\\provision-runner.ps1; $winlogon = Get-ItemProperty \'HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon\'; [PSCustomObject]@{ Runner_Script_Exists = $scriptExists; Task_Name = $task.TaskName; Task_State = $task.State; Auto_Admin_Logon = $winlogon.AutoAdminLogon; Default_User_Name = $winlogon.DefaultUserName } | Format-List"'
        code, out, err = ssh_exec(prov_cmd)
        print("\n--- Provisioning Infrastructure ---")
        print(out)
        print("-----------------------------------")
        prov_ok = code == 0 and "Runner_Script_Exists : True" in out and "ImageProvisionRunner" in out
        record_test("Provisioning Runner & Scheduled Task", prov_ok, out)

        # Test 6: File System I/O and Dual Shell Execution (PowerShell & CMD)
        log("Test 6: Testing Dual-Shell Execution (PowerShell & CMD) and File I/O...", "INFO")
        io_cmd = 'powershell -NoProfile -Command "$testFile = \'C:\\test_ssh_io.txt\'; $expected = \'OpenSSH Verification Test String \' + (Get-Date).Ticks; Set-Content -Path $testFile -Value $expected -Force; $readBack = Get-Content -Path $testFile; Remove-Item -Path $testFile -Force; if ($readBack -eq $expected) { Write-Output PS_FILE_IO_OK } else { Write-Output PS_FILE_IO_FAILED }; cmd.exe /c echo CMD_SHELL_EXECUTION_OK"'
        code, out, err = ssh_exec(io_cmd)
        print("\n--- Shell & I/O Execution ---")
        print(out)
        print("-----------------------------")
        io_ok = code == 0 and "PS_FILE_IO_OK" in out and "CMD_SHELL_EXECUTION_OK" in out
        record_test("Dual Shell & File I/O Execution", io_ok, out)

        # Test 7: Network Configuration (VirtIO NetKVM IP & Gateway)
        log("Test 7: Inspecting Guest Network Interface & IP Configuration...", "INFO")
        net_cmd = 'powershell -NoProfile -Command "Get-NetIPAddress -InterfaceAlias \'Ethernet*\' | Where-Object { $_.AddressFamily -eq \'IPv4\' } | Select-Object IPAddress, InterfaceAlias, PrefixLength | Format-List"'
        code, out, err = ssh_exec(net_cmd)
        print("\n--- Guest Network Interface ---")
        print(out)
        print("-------------------------------")
        net_ok = code == 0 and "10.0.2." in out
        record_test("Guest Network IP Configuration", net_ok, out)

        # 8. Graceful Shutdown via SSH
        log("Executing Graceful Shutdown via OpenSSH...", "STEP")
        code, out, err = ssh_exec('powershell -NoProfile -Command "Stop-Computer -Force"', timeout=10)
        log("Stop-Computer command dispatched.", "INFO")

        log("Waiting for QEMU process to terminate cleanly...", "INFO")
        try:
            qemu_proc.wait(timeout=60)
            log(f"QEMU process exited cleanly with code {qemu_proc.returncode}.", "PASS")
            record_test("Graceful Shutdown via SSH", True, f"QEMU return code: {qemu_proc.returncode}")
        except subprocess.TimeoutExpired:
            log("QEMU did not terminate within 60s, terminating...", "WARN")
            qemu_proc.terminate()
            qemu_proc.wait(timeout=10)
            record_test("Graceful Shutdown via SSH", False, "Timeout waiting for shutdown")

    finally:
        if qemu_proc.poll() is None:
            log("Cleaning up QEMU process...", "INFO")
            qemu_proc.terminate()
            try:
                qemu_proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                qemu_proc.kill()

        if OVERLAY_IMAGE.exists():
            log(f"Removing transient test overlay: {OVERLAY_IMAGE}", "INFO")
            OVERLAY_IMAGE.unlink()
        if MONITOR_SOCK.exists():
            MONITOR_SOCK.unlink()

    # Save results to JSON
    with open(TEST_RESULTS_FILE, "w", encoding="utf-8") as f:
        json.dump(test_results, f, indent=2, ensure_ascii=False)
    log(f"Test results saved to {TEST_RESULTS_FILE}", "INFO")

    print("\n" + "=" * 70)
    print("                       TEST SUITE SUMMARY")
    print("=" * 70)
    all_passed = True
    for t in test_results:
        status_str = "\033[1;32m[PASS]\033[0m" if t["passed"] else "\033[1;31m[FAIL]\033[0m"
        print(f" {status_str} {t['name']}")
        if not t["passed"]:
            all_passed = False
            print(f"        Reason: {t['details']}")
    print("=" * 70)
    return 0 if all_passed else 1

if __name__ == "__main__":
    sys.exit(main())
