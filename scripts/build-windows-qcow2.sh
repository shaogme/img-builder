#!/usr/bin/env bash
# ==============================================================================
# Script: build-windows-qcow2.sh
# Description: Automated Windows Server 2025 Core QCOW2 Image Builder with Rust GNU
# Target OS: Windows Server 2025 ServerStandardCore (Build 26100.1)
# ==============================================================================
set -euo pipefail

WORKSPACE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ISO_DIR="${WORKSPACE_DIR}/ISO"
BUILD_DIR="${WORKSPACE_DIR}/build"
OUTPUT_DIR="${WORKSPACE_DIR}/output"
PACKAGES_DIR="${WORKSPACE_DIR}/packages"

WIN_ISO="${ISO_DIR}/26100.1_SERVERSTANDARD_X64_EN-US.ISO"
VIRTIO_ISO="${ISO_DIR}/virtio-win-0.1.302.iso"
UNATTEND_ISO="${BUILD_DIR}/unattend.iso"
RAW_QCOW2="${OUTPUT_DIR}/win2025-core-rust-gnu-raw.qcow2"
FINAL_QCOW2="${OUTPUT_DIR}/win2025-core-rust-gnu.qcow2"

DISK_SIZE="64G"
MEMORY_MB="8192"
CPUS="4"
VNC_PORT="1" # VNC available at 127.0.0.1:5901

ADMIN_USER="Administrator"
ADMIN_PASS="Admin1234!"
METADATA_FILE="${OUTPUT_DIR}/win2025-core-rust-gnu.json"

mkdir -p "${OUTPUT_DIR}"
exec > >(tee -a "${OUTPUT_DIR}/build.log") 2>&1

echo "====================================================================="
echo "==> Starting Windows Server 2025 Core Image Build Pipeline"
echo "====================================================================="

# Check ISO files
if [[ ! -f "${WIN_ISO}" ]]; then
    echo "[Error] Windows ISO not found at ${WIN_ISO}" >&2
    exit 1
fi
if [[ ! -f "${VIRTIO_ISO}" ]]; then
    echo "[Error] VirtIO ISO not found at ${VIRTIO_ISO}" >&2
    exit 1
fi

mkdir -p "${BUILD_DIR}/iso_root/packages" "${BUILD_DIR}/iso_root/sources" "${OUTPUT_DIR}"

echo "==> [Phase 1/4] Preparing unattended installation ISO (unattend.iso)..."
cp "${WORKSPACE_DIR}/templates/Autounattend.xml" "${BUILD_DIR}/iso_root/Autounattend.xml"
cp "${WORKSPACE_DIR}/templates/provision.ps1" "${BUILD_DIR}/iso_root/provision.ps1"
cat << 'EOF' > "${BUILD_DIR}/iso_root/sources/ei.cfg"
[Channel]
OEM
[VL]
0
EOF

# Convert CRLF line endings for Windows
if command -v unix2dos >/dev/null 2>&1; then
    unix2dos "${BUILD_DIR}/iso_root/Autounattend.xml" "${BUILD_DIR}/iso_root/provision.ps1"
fi

# Copy pre-downloaded offline packages if available
if [[ -d "${PACKAGES_DIR}" ]]; then
    echo "==> Copying offline packages into unattend ISO..."
    cp -r "${PACKAGES_DIR}/"* "${BUILD_DIR}/iso_root/packages/" || true
fi

# Build unattend.iso with genisoimage
genisoimage -quiet -l -o "${UNATTEND_ISO}" -J -r -V "OEMDRV" "${BUILD_DIR}/iso_root"
echo "==> Unattend ISO generated at: ${UNATTEND_ISO}"

# Initialize blank QCOW2 disk
echo "==> [Phase 3/5] Allocating initial QCOW2 disk image (${DISK_SIZE})..."
rm -f "${RAW_QCOW2}"
qemu-img create -f qcow2 "${RAW_QCOW2}" "${DISK_SIZE}"

# ------------------------------------------------------------------------------
# Stage 1: Windows Setup Phase
# ------------------------------------------------------------------------------
echo "====================================================================="
echo "==> [Stage 1: Windows Setup Phase]"
echo "    - Booting from Windows Server 2025 ISO"
echo "    - Automated WinPE partitioning & Core image application"
echo "    - VNC: 127.0.0.1:${VNC_PORT} (display :${VNC_PORT})"
echo "====================================================================="

MONITOR_SOCK="${BUILD_DIR}/qemu-monitor.sock"
rm -f "${MONITOR_SOCK}"

# Launch boot monitor in background to handle any CD boot prompts
python3 "${WORKSPACE_DIR}/scripts/monitor-boot.py" "${MONITOR_SOCK}" &
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
    -netdev user,id=net0 \
    -device virtio-net-pci,netdev=net0 \
    -vnc "127.0.0.1:${VNC_PORT}" \
    -display none \
    -monitor "unix:${MONITOR_SOCK},server,nowait" \
    -boot order=d \
    -no-reboot

wait "${MONITOR_PID}" 2>/dev/null || true
echo "==> Stage 1 completed! Windows Setup finished file installation and rebooted."

# ------------------------------------------------------------------------------
# Stage 2: FirstLogon & Provisioning Phase
# ------------------------------------------------------------------------------
echo "====================================================================="
echo "==> [Stage 2: FirstLogon & Provisioning Phase]"
echo "    - Booting from hard disk"
echo "    - Running provision.ps1: VirtIO tools, MinGW-w64, Rust GNU"
echo "    - Running compilation verification test"
echo "====================================================================="

qemu-system-x86_64 \
    -enable-kvm \
    -m "${MEMORY_MB}" \
    -smp "${CPUS}" \
    -cpu host,hv_relaxed,hv_spinlocks=0x1fff,hv_vapic,hv_time \
    -drive "file=${RAW_QCOW2},if=virtio,format=qcow2,cache=writeback" \
    -drive "file=${VIRTIO_ISO},media=cdrom,index=1" \
    -drive "file=${UNATTEND_ISO},media=cdrom,index=2" \
    -netdev user,id=net0 \
    -device virtio-net-pci,netdev=net0 \
    -vnc "127.0.0.1:${VNC_PORT}" \
    -display none \
    -monitor "unix:${MONITOR_SOCK},server,nowait" \
    -boot order=c \
    -no-reboot

echo "==> Stage 2 completed! System has executed provision.ps1 and cleanly shut down."

# ------------------------------------------------------------------------------
# Stage 3: Compression & Final Output
# ------------------------------------------------------------------------------
echo "====================================================================="
echo "==> [Stage 3: QCOW2 Compression & Finalization]"
echo "====================================================================="

rm -f "${FINAL_QCOW2}"
qemu-img convert -f qcow2 -O qcow2 -c -p "${RAW_QCOW2}" "${FINAL_QCOW2}"

# Clean up raw image and build cache
rm -f "${RAW_QCOW2}" "${UNATTEND_ISO}"
rm -rf "${BUILD_DIR}"

echo "==> Generating image metadata and credentials configuration (${METADATA_FILE})..."
cat << EOF > "${METADATA_FILE}"
{
  "image": {
    "filename": "$(basename "${FINAL_QCOW2}")",
    "path": "${FINAL_QCOW2}",
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
  "toolchains": {
    "rust": {
      "host_triple": "x86_64-pc-windows-gnu",
      "channel": "stable",
      "msvc_dependent": false,
      "cargo_home": "C:\\\\Users\\\\${ADMIN_USER}\\\\.cargo",
      "rustup_home": "C:\\\\Users\\\\${ADMIN_USER}\\\\.rustup"
    },
    "c_cpp": {
      "toolchain": "w64devkit",
      "flavor": "MinGW-w64",
      "path": "C:\\\\tools\\\\w64devkit\\\\bin"
    }
  },
  "drivers": {
    "virtio_guest_tools": true,
    "qemu_guest_agent": true
  }
}
EOF

echo "====================================================================="
echo "==> BUILD SUCCEEDED!"
echo "==> Output QCOW2 image: ${FINAL_QCOW2}"
ls -lh "${FINAL_QCOW2}"
echo "==> Credentials & Metadata: ${METADATA_FILE}"
cat "${METADATA_FILE}"
qemu-img info "${FINAL_QCOW2}"
echo "====================================================================="
