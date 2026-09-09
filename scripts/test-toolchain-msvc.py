#!/usr/bin/env python3
"""
Toolchain Test Suite via OpenSSH: MSVC Image (win2025-core-rust-msvc.qcow2)
Executes toolchain tests over OpenSSH:
- Visual Studio 2022 Build Tools detection (vswhere.exe)
- MSVC C/C++ compiler (cl.exe)
- MSVC Linker (link.exe)
- Rustc MSVC (x86_64-pc-windows-msvc)
- Cargo
- Native C++ compilation & execution (cl.exe)
- Cargo binary project build & execution (cargo build & run)
"""

import sys
import time
import subprocess
import json
from pathlib import Path

WORKSPACE = Path("/workspace")
BUILD_DIR = WORKSPACE / "build"
MSVC_IMAGE = WORKSPACE / "output" / "win2025-core-rust-msvc.qcow2"
OVERLAY = BUILD_DIR / "test-msvc-toolchain-overlay.qcow2"
RESULTS_FILE = BUILD_DIR / "test-msvc-toolchain-results.json"

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
    print(" Toolchain Test Suite via OpenSSH: MSVC Image (win2025-core-rust-msvc.qcow2)")
    print("=" * 70)

    if not MSVC_IMAGE.is_file():
        log(f"MSVC image not found: {MSVC_IMAGE}", "FAIL")
        sys.exit(1)

    BUILD_DIR.mkdir(parents=True, exist_ok=True)
    if OVERLAY.exists():
        OVERLAY.unlink()

    log("Preparing transient CoW test overlay...", "STEP")
    subprocess.run([
        "qemu-img", "create", "-f", "qcow2",
        "-b", str(MSVC_IMAGE.resolve()),
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

        log("OpenSSH connected. Running MSVC Toolchain Tests...", "STEP")

        # 1. VS 2022 Build Tools Detection
        log("1. Visual Studio 2022 Build Tools Detection", "INFO")
        vswhere_cmd = 'cmd.exe /c ""C:\\Program Files (x86)\\Microsoft Visual Studio\\Installer\\vswhere.exe" -latest -products * -property displayName"'
        code, out, err = ssh_exec(vswhere_cmd)
        if not out:
            code, out, err = ssh_exec("powershell -NoProfile -Command \"& 'C:\\Program Files (x86)\\Microsoft Visual Studio\\Installer\\vswhere.exe' -latest -products * -property displayName\"")
        print(f"{out}\n")
        record("Visual Studio 2022 Build Tools Detection", "Visual Studio" in out, out or err)

        # 2. MSVC cl.exe
        log("2. MSVC C/C++ Compiler (cl.exe)", "INFO")
        cl_cmd = 'cmd.exe /c "call C:\\BuildTools\\Common7\\Tools\\VsDevCmd.bat && cl.exe 2>&1"'
        code, out, err = ssh_exec(cl_cmd)
        print(f"{out.splitlines()[0] if out else ''}\n")
        record("MSVC C/C++ Compiler (cl.exe)", "Microsoft (R) C/C++ Optimizing Compiler" in out, out.splitlines()[0] if out else "")

        # 3. MSVC link.exe
        log("3. MSVC Linker (link.exe)", "INFO")
        link_cmd = 'cmd.exe /c "call C:\\BuildTools\\Common7\\Tools\\VsDevCmd.bat && link.exe 2>&1"'
        code, out, err = ssh_exec(link_cmd)
        print(f"{out.splitlines()[0] if out else ''}\n")
        record("MSVC Incremental Linker (link.exe)", "Microsoft (R) Incremental Linker" in out, out.splitlines()[0] if out else "")

        # 4. Rustc MSVC
        log("4. Rustc MSVC Toolchain (x86_64-pc-windows-msvc)", "INFO")
        code, out, err = ssh_exec("rustc -Vv")
        print(f"{out}\n")
        record("Rustc MSVC Toolchain (x86_64-pc-windows-msvc)", code == 0 and "x86_64-pc-windows-msvc" in out, out.splitlines()[0] if out else "")

        # 5. Cargo
        log("5. Cargo Package Manager", "INFO")
        code, out, err = ssh_exec("cargo -V")
        print(f"{out}\n")
        record("Cargo Package Manager", code == 0 and "cargo" in out.lower(), out)

        # 6. Native C++ Compilation with cl.exe & Execution
        log("6. Native C++ Compilation & Execution (cl.exe)", "INFO")
        create_src = "powershell -NoProfile -Command \"[System.IO.File]::WriteAllBytes('C:\\test_msvc.cpp', [System.Convert]::FromBase64String('I2luY2x1ZGUgPGlvc3RyZWFtPgppbnQgbWFpbigpIHsgc3RkOjpjb3V0IDw8ICJIRUxMT19GUk9NX01TVkNfQ0xfQ09NUElMRVIiIDw8IHN0ZDo6ZW5kbDsgcmV0dXJuIDA7IH0K'))\""
        ssh_exec(create_src, timeout=30)
        compile_run = 'cmd.exe /c "call C:\\BuildTools\\Common7\\Tools\\VsDevCmd.bat && cl.exe /EHsc /nologo /Fe:C:\\test_msvc.exe C:\\test_msvc.cpp && C:\\test_msvc.exe && del C:\\test_msvc.*"'
        code, out, err = ssh_exec(compile_run, timeout=60)
        print(f"Output: {out}\n")
        record("Native C++ Compilation & Execution (cl.exe)", "HELLO_FROM_MSVC_CL_COMPILER" in out, out or err)

        # 7. Cargo MSVC Project Build & Execution
        log("7. Cargo Project Build & Execution (x86_64-pc-windows-msvc)", "INFO")
        cargo_cmd = 'powershell -NoProfile -Command "if (Test-Path C:\\cargo_msvc_demo) { Remove-Item -Recurse -Force C:\\cargo_msvc_demo }; cargo new --bin C:\\cargo_msvc_demo; Set-Location C:\\cargo_msvc_demo; cargo build; & .\\target\\debug\\cargo_msvc_demo.exe; Set-Location C:\\; Remove-Item -Recurse -Force C:\\cargo_msvc_demo -ErrorAction SilentlyContinue"'
        code, out, err = ssh_exec(cargo_cmd, timeout=120)
        print(f"Output: {out}\n")
        record("Cargo Project Build & Execution (x86_64-pc-windows-msvc)", code == 0 and "Hello, world!" in out, out)

        # 8. Cargo Install Target in PATH & Direct Binary Execution
        log("8. Cargo Install Target in PATH & Direct Binary Execution", "INFO")
        install_cmd = 'powershell -NoProfile -Command "if (Test-Path C:\\cargo_install_msvc_demo) { Remove-Item -Recurse -Force C:\\cargo_install_msvc_demo }; cargo new --bin C:\\cargo_install_msvc_demo; Set-Location C:\\cargo_install_msvc_demo; cargo install --debug --path .; Set-Location C:\\; $binLoc = (Get-Command cargo_install_msvc_demo.exe -ErrorAction Stop).Source; Write-Host \\"RESOLVED_BIN: $binLoc\\"; $runOut = & cargo_install_msvc_demo.exe; Write-Host \\"EXEC_OUTPUT: $runOut\\"; cargo uninstall cargo_install_msvc_demo; Remove-Item -Recurse -Force C:\\cargo_install_msvc_demo -ErrorAction SilentlyContinue"'
        code, out, err = ssh_exec(install_cmd, timeout=120)
        print(f"Output: {out}\n")
        passed = code == 0 and "RESOLVED_BIN:" in out and ".cargo" in out.lower() and "Hello, world!" in out
        record("Cargo Install Target in PATH & Direct Binary Execution", passed, out)

        # 9. cargo-binstall
        log("9. cargo-binstall Tool Verification", "INFO")
        code, out, err = ssh_exec('cargo binstall -V')
        print(f"Output: {out}\n")
        record("cargo-binstall Tool", code == 0 and "cargo-binstall" in out.lower() or code == 0 and any(c.isdigit() for c in out), out)

        # 10. Tools Installed via cargo-binstall
        log("10. Cargo Ecosystem Tools Verification (Installed via cargo-binstall)", "INFO")
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
    print("          RUST MSVC TOOLCHAIN TEST RESULTS (OVER OPENSSH)")
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
