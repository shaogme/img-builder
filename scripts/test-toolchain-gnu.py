#!/usr/bin/env python3
"""
Toolchain Test Suite via OpenSSH: GNU Image (win2025-core-rust-gnu.qcow2)
Executes toolchain tests over OpenSSH:
- GCC compiler
- G++ compiler
- GNU Make
- Rustc GNU (x86_64-pc-windows-gnu)
- Cargo
- C program compilation & execution (gcc)
- C++ program compilation & execution (g++)
- Cargo binary project build & execution (cargo build & run)
"""

import sys
import time
import subprocess
import json
from pathlib import Path

WORKSPACE = Path("/workspace")
BUILD_DIR = WORKSPACE / "build"
GNU_IMAGE = WORKSPACE / "output" / "win2025-core-rust-gnu.qcow2"
OVERLAY = BUILD_DIR / "test-gnu-toolchain-overlay.qcow2"
RESULTS_FILE = BUILD_DIR / "test-gnu-toolchain-results.json"

SSH_HOST = "127.0.0.1"
SSH_PORT = 2222
SSH_USER = "Administrator"
SSH_PASS = "Admin1234!"

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

def ssh_exec(cmd, timeout=90):
    ssh_cmd = [
        "sshpass", "-p", SSH_PASS,
        "ssh",
        "-p", str(SSH_PORT),
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", "LogLevel=ERROR",
        "-o", "ConnectTimeout=10",
        f"{SSH_USER}@{SSH_HOST}",
        cmd
    ]
    try:
        p = subprocess.run(ssh_cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    except subprocess.TimeoutExpired:
        return -1, "", "Command timed out"

def main():
    print("=" * 70)
    print(" Toolchain Test Suite via OpenSSH: GNU Image (win2025-core-rust-gnu.qcow2)")
    print("=" * 70)

    if not GNU_IMAGE.is_file():
        log(f"GNU image not found: {GNU_IMAGE}", "FAIL")
        sys.exit(1)

    BUILD_DIR.mkdir(parents=True, exist_ok=True)
    if OVERLAY.exists():
        OVERLAY.unlink()

    log("Preparing transient CoW test overlay...", "STEP")
    subprocess.run([
        "qemu-img", "create", "-f", "qcow2",
        "-b", str(GNU_IMAGE.resolve()),
        "-F", "qcow2",
        str(OVERLAY)
    ], check=True)

    qemu_cmd = [
        "qemu-system-x86_64",
        "-enable-kvm",
        "-m", "8192",
        "-smp", "4",
        "-cpu", "host,hv_relaxed,hv_spinlocks=0x1fff,hv_vapic,hv_time",
        "-drive", f"file={OVERLAY},if=virtio,format=qcow2,cache=writeback",
        "-netdev", f"user,id=net0,hostfwd=tcp::{SSH_PORT}-:22",
        "-device", "virtio-net-pci,netdev=net0",
        "-vnc", "127.0.0.1:1",
        "-display", "none",
        "-boot", "order=c",
        "-no-reboot"
    ]

    log("Starting VM...", "STEP")
    proc = subprocess.Popen(qemu_cmd)

    test_results = []
    def record(name, passed, details=""):
        test_results.append({"name": name, "passed": passed, "details": details})
        if passed:
            log(f"{name}: PASSED", "PASS")
        else:
            log(f"{name}: FAILED - {details}", "FAIL")

    try:
        log("Waiting for OpenSSH channel to be ready...", "INFO")
        ready = False
        for _ in range(30):
            time.sleep(2)
            c, o, e = ssh_exec("echo READY", timeout=5)
            if c == 0 and "READY" in o:
                ready = True
                break

        if not ready:
            log("OpenSSH channel not reachable within timeout", "FAIL")
            return 1

        log("OpenSSH connected. Running Toolchain Tests...", "STEP")

        # 1. GCC
        log("1. GCC Compiler Verification", "INFO")
        code, out, err = ssh_exec("gcc --version")
        print(f"{out}\n")
        record("GCC Compiler (w64devkit)", code == 0 and ("gcc" in out.lower() or "free software foundation" in out.lower()), out.splitlines()[0] if out else "")

        # 2. G++
        log("2. G++ Compiler Verification", "INFO")
        code, out, err = ssh_exec("g++ --version")
        print(f"{out}\n")
        record("G++ Compiler (w64devkit)", code == 0 and "g++" in out.lower(), out.splitlines()[0] if out else "")

        # 3. GNU Make
        log("3. GNU Make Verification", "INFO")
        code, out, err = ssh_exec("make --version")
        print(f"{out}\n")
        record("GNU Make (w64devkit)", code == 0 and "gnu make" in out.lower(), out.splitlines()[0] if out else "")

        # 4. Rustc GNU
        log("4. Rustc GNU Toolchain (x86_64-pc-windows-gnu)", "INFO")
        code, out, err = ssh_exec("rustc -Vv")
        print(f"{out}\n")
        record("Rustc GNU Toolchain (x86_64-pc-windows-gnu)", code == 0 and "x86_64-pc-windows-gnu" in out, out.splitlines()[0] if out else "")

        # 5. Cargo
        log("5. Cargo Package Manager", "INFO")
        code, out, err = ssh_exec("cargo -V")
        print(f"{out}\n")
        record("Cargo Package Manager", code == 0 and "cargo" in out.lower(), out)

        # 6. C Compilation & Execution
        log("6. C Compilation & Execution (gcc)", "INFO")
        c_cmd = 'cmd.exe /c "cd /d C:\\ && echo #include ^<stdio.h^> > test_c.c && echo int main() { printf(\"HELLO_FROM_GCC_COMPILER\\n\"); return 0; } >> test_c.c && gcc test_c.c -o test_c.exe && test_c.exe && del test_c.c test_c.exe"'
        code, out, err = ssh_exec(c_cmd)
        print(f"Output: {out}\n")
        record("C Program Compilation & Execution (gcc)", code == 0 and "HELLO_FROM_GCC_COMPILER" in out, out)

        # 7. C++ Compilation & Execution
        log("7. C++ Compilation & Execution (g++)", "INFO")
        cpp_cmd = 'cmd.exe /c "cd /d C:\\ && echo #include ^<iostream^> > test_cpp.cpp && echo int main() { std::cout ^<^< \"HELLO_FROM_GPP_COMPILER\" ^<^< std::endl; return 0; } >> test_cpp.cpp && g++ test_cpp.cpp -o test_cpp.exe && test_cpp.exe && del test_cpp.cpp test_cpp.exe"'
        code, out, err = ssh_exec(cpp_cmd)
        print(f"Output: {out}\n")
        record("C++ Program Compilation & Execution (g++)", code == 0 and "HELLO_FROM_GPP_COMPILER" in out, out)

        # 8. Cargo Project Build & Execution
        log("8. Cargo Project Build & Execution", "INFO")
        cargo_cmd = 'powershell -NoProfile -Command "if (Test-Path C:\\cargo_gnu_demo) { Remove-Item -Recurse -Force C:\\cargo_gnu_demo }; cargo new --bin C:\\cargo_gnu_demo; Set-Location C:\\cargo_gnu_demo; cargo build; & .\\target\\debug\\cargo_gnu_demo.exe; Set-Location C:\\; Remove-Item -Recurse -Force C:\\cargo_gnu_demo -ErrorAction SilentlyContinue"'
        code, out, err = ssh_exec(cargo_cmd, timeout=90)
        print(f"Output: {out}\n")
        record("Cargo Project Build & Execution (x86_64-pc-windows-gnu)", code == 0 and "Hello, world!" in out, out)

        # 9. Cargo Install Target in PATH & Direct Binary Execution
        log("9. Cargo Install Target in PATH & Direct Binary Execution", "INFO")
        install_cmd = 'powershell -NoProfile -Command "if (Test-Path C:\\cargo_install_gnu_demo) { Remove-Item -Recurse -Force C:\\cargo_install_gnu_demo }; cargo new --bin C:\\cargo_install_gnu_demo; Set-Location C:\\cargo_install_gnu_demo; cargo install --debug --path .; Set-Location C:\\; $binLoc = (Get-Command cargo_install_gnu_demo.exe -ErrorAction Stop).Source; Write-Host \\"RESOLVED_BIN: $binLoc\\"; $runOut = & cargo_install_gnu_demo.exe; Write-Host \\"EXEC_OUTPUT: $runOut\\"; cargo uninstall cargo_install_gnu_demo; Remove-Item -Recurse -Force C:\\cargo_install_gnu_demo -ErrorAction SilentlyContinue"'
        code, out, err = ssh_exec(install_cmd, timeout=120)
        print(f"Output: {out}\n")
        passed = code == 0 and "RESOLVED_BIN:" in out and ".cargo" in out.lower() and "Hello, world!" in out
        record("Cargo Install Target in PATH & Direct Binary Execution", passed, out)

        # 10. Visual C++ Redistributable (vc_redist)
        log("10. Visual C++ Redistributable Verification", "INFO")
        code, out, err = ssh_exec('powershell -NoProfile -Command "Test-Path C:\\Windows\\System32\\vcruntime140.dll"')
        print(f"Output: {out}\n")
        record("Visual C++ Redistributable (vcruntime140.dll)", code == 0 and "True" in out, "vcruntime140.dll in System32")

        # 11. cargo-binstall
        log("11. cargo-binstall Tool Verification", "INFO")
        code, out, err = ssh_exec('cargo binstall -V')
        print(f"Output: {out}\n")
        record("cargo-binstall Tool", code == 0 and "cargo-binstall" in out.lower() or code == 0 and any(c.isdigit() for c in out), out)

        # 12. Tools Installed via cargo-binstall
        log("12. Cargo Ecosystem Tools Verification (Installed via cargo-binstall)", "INFO")
        binstall_checks = [
            ("sccache", "sccache --version"),
            ("cargo-nextest", "cargo nextest --version"),
            ("cargo-sweep", "cargo sweep --version"),
            ("cargo-geiger", "cargo geiger --version"),
            ("cargo-audit", "cargo audit --version"),
            ("flamegraph", "cargo flamegraph --version"),
            ("samply", "samply --version"),
            ("cargo-show-asm", "cargo asm --version"),
            ("cargo-expand", "cargo expand --version"),
            ("cargo-bloat", "cargo bloat --version"),
        ]
        for tool_name, tool_cmd in binstall_checks:
            code, out, err = ssh_exec(tool_cmd)
            first_line = out.splitlines()[0] if out else err
            print(f"[{tool_name}]: {first_line}")
            record(f"Tool: {tool_name} (via cargo-binstall)", code == 0, first_line)

        # Shutdown
        log("Shutting down VM...", "STEP")
        ssh_exec('powershell -NoProfile -Command "Stop-Computer -Force"', timeout=10)
        proc.wait(60)
        log("VM shut down cleanly.", "INFO")

    finally:
        if proc.poll() is None:
            proc.terminate()
            proc.wait(5)
        OVERLAY.unlink(missing_ok=True)

    with open(RESULTS_FILE, "w", encoding="utf-8") as f:
        json.dump(test_results, f, indent=2, ensure_ascii=False)

    print("\n" + "=" * 70)
    print("           RUST GNU TOOLCHAIN TEST RESULTS (OVER OPENSSH)")
    print("=" * 70)
    all_passed = True
    for t in test_results:
        status_str = "\033[1;32m[PASS]\033[0m" if t["passed"] else "\033[1;31m[FAIL]\033[0m"
        print(f" {status_str} {t['name']}")
        if not t["passed"]:
            all_passed = False
            print(f"        Details: {t['details']}")
    print("=" * 70)
    return 0 if all_passed else 1

if __name__ == "__main__":
    sys.exit(main())
