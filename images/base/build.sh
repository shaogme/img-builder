#!/usr/bin/env bash
# ==============================================================================
# Script: images/base/build.sh
# Description: Automated Base Image Builder (win2025-core.qcow2)
# OS: Windows Server 2025 Standard Core (Build 26100.1)
# ==============================================================================
set -euo pipefail

IMAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/common.sh
source "${IMAGE_DIR}/../../scripts/common.sh"
# shellcheck source=../../scripts/fetch-common.sh
source "${SCRIPTS_DIR}/fetch-common.sh"

RAW_QCOW2="${BUILD_DIR}/win2025-core-raw.qcow2"
UNATTEND_ISO="${BUILD_DIR}/base-unattend.iso"
LOG_FILE="${OUTPUT_DIR}/build-base.log"

exec > >(tee -a "${LOG_FILE}") 2>&1

log_step "Starting Base Image Build: win2025-core.qcow2"
check_base_inputs

# Pre-fetch offline OpenSSH on host
log_step "[Phase 1/4] Ensuring offline Win32-OpenSSH is available on host..."
fetch_win32_openssh

if [[ ! -d "${PACKAGES_DIR}/openssh" ]] || [[ ! -f "${PACKAGES_DIR}/openssh/install-sshd.ps1" ]]; then
    log_error "Win32-OpenSSH package missing or invalid at ${PACKAGES_DIR}/openssh!"
    exit 1
fi

# Prepare Unattend ISO
log_step "[Phase 1/4] Preparing Base Unattend ISO..."
ISO_ROOT="${BUILD_DIR}/base_iso_root"
rm -rf "${ISO_ROOT}"
mkdir -p "${ISO_ROOT}/sources"

cp "${IMAGE_DIR}/Autounattend.xml" "${ISO_ROOT}/Autounattend.xml"
cp "${IMAGE_DIR}/provision.ps1" "${ISO_ROOT}/provision-base.ps1"
cp "${IMAGE_DIR}/provision.ps1" "${ISO_ROOT}/provision.ps1"
cp "${IMAGE_DIR}/provision-runner.ps1" "${ISO_ROOT}/provision-runner.ps1"

# Stage offline OpenSSH payload pre-fetched on host
log_info "Staging offline Win32-OpenSSH into Base Unattend ISO..."
cp -r "${PACKAGES_DIR}/openssh" "${ISO_ROOT}/openssh"

cat << 'CMD_EOF' > "${ISO_ROOT}/run-provision.cmd"
@echo off
echo [%date% %time%] run-provision.cmd invoked from drive %~d0 >> C:\provision-bootstrap.log
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0provision-base.ps1" >> C:\provision-bootstrap.log 2>&1
set EXIT_CODE=%ERRORLEVEL%
echo [%date% %time%] run-provision.cmd finished with exit code %EXIT_CODE% >> C:\provision-bootstrap.log
if %EXIT_CODE% NEQ 0 (
    echo [ERROR] Base provisioning failed with exit code %EXIT_CODE%! Shutting down VM in 10 seconds... >> C:\provision-bootstrap.log
    timeout /t 10 /nobreak >nul 2>&1
    shutdown /s /t 0 /f
)
CMD_EOF

cat << 'CFG_EOF' > "${ISO_ROOT}/sources/ei.cfg"
[Channel]
OEM
[VL]
0
CFG_EOF

make_iso "${UNATTEND_ISO}" "${ISO_ROOT}" "OEMDRV"

# Initialize raw disk
log_step "[Phase 2/4] Allocating raw QCOW2 disk (${DISK_SIZE})..."
rm -f "${RAW_QCOW2}"
qemu-img create -f qcow2 "${RAW_QCOW2}" "${DISK_SIZE}"

# Stage 1: Windows Setup Phase
log_step "[Stage 1] Windows Setup Phase (WinPE partitioning & file installation)..."
MONITOR_SOCK="${BUILD_DIR}/qemu-monitor-base.sock"
rm -f "${MONITOR_SOCK}"

python3 "${SCRIPTS_DIR}/monitor-boot.py" "${MONITOR_SOCK}" &
MONITOR_PID=$!

qemu-system-x86_64 \
    -enable-kvm \
    -m "${MEMORY_MB}" \
    -smp "${CPUS}" \
    -cpu host,hv_relaxed,hv_spinlocks=0x1fff,hv_vapic,hv_time \
    -drive "file=${RAW_QCOW2},if=virtio,format=qcow2,cache=writeback" \
    -drive "file=${WIN_ISO},media=cdrom,index=1" \
    -drive "file=${VIRTIO_ISO},media=cdrom,index=2" \
    -drive "file=${UNATTEND_ISO},media=cdrom,index=3" \
    -nic none \
    -vnc "127.0.0.1:${VNC_PORT}" \
    -display none \
    -monitor "unix:${MONITOR_SOCK},server,nowait" \
    -boot order=d \
    -no-reboot

wait "${MONITOR_PID}" 2>/dev/null || true
log_info "Stage 1 completed! Windows Setup finished installation."
rm -f "${MONITOR_SOCK}"
sleep 3

# Stage 2: FirstLogon Base Provisioning
log_step "[Stage 2] FirstLogon Base Provisioning (VirtIO tools, SSH, Provision Runner)..."
qemu-system-x86_64 \
    -enable-kvm \
    -m "${MEMORY_MB}" \
    -smp "${CPUS}" \
    -cpu host,hv_relaxed,hv_spinlocks=0x1fff,hv_vapic,hv_time \
    -drive "file=${RAW_QCOW2},if=virtio,format=qcow2,cache=writeback" \
    -drive "file=${VIRTIO_ISO},media=cdrom,index=1" \
    -drive "file=${UNATTEND_ISO},media=cdrom,index=2" \
    -nic none \
    -vnc "127.0.0.1:${VNC_PORT}" \
    -display none \
    -monitor "unix:${MONITOR_SOCK},server,nowait" \
    -boot order=c

log_info "Stage 2 completed! Base system provisioned and cleanly shut down."

# Stage 3: Compression & Finalization
convert_and_compress "${RAW_QCOW2}" "${BASE_IMAGE}"

# Clean up raw artifacts
rm -f "${RAW_QCOW2}" "${UNATTEND_ISO}"
rm -rf "${ISO_ROOT}"

# Generate Base Metadata JSON
cat << JSON_EOF > "${BASE_METADATA}"
{
  "image": {
    "filename": "$(basename "${BASE_IMAGE}")",
    "path": "${BASE_IMAGE}",
    "format": "qcow2",
    "virtual_size": "${DISK_SIZE}",
    "compression": "zlib",
    "created_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  },
  "os": {
    "name": "Windows Server 2025 Standard",
    "edition": "ServerStandardCore",
    "build": "26100.1",
    "arch": "x86_64",
    "gui": false
  },
  "credentials": {
    "username": "${ADMIN_USER}",
    "password": "${ADMIN_PASS}",
    "auto_logon": true
  },
  "network_and_remote": {
    "ssh": {
      "enabled": true,
      "port": 22,
      "command": "ssh ${ADMIN_USER}@<VM_IP> -p 22"
    },
    "vnc": {
      "port": 5901,
      "display": ":1"
    }
  },
  "drivers": {
    "virtio_guest_tools": true,
    "qemu_guest_agent": true
  },
  "provisioning": {
    "runner_enabled": true,
    "task_name": "ImageProvisionRunner"
  }
}
JSON_EOF

log_step "Base Image Build Completed Successfully!"
echo "==> Base QCOW2: ${BASE_IMAGE}"
echo "==> Metadata:   ${BASE_METADATA}"
qemu-img info "${BASE_IMAGE}"
