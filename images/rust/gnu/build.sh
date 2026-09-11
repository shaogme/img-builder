#!/usr/bin/env bash
# ==============================================================================
# Script: images/rust/gnu/build.sh
# Description: Automated Rust GNU Image Builder (win2025-core-rust-gnu.qcow2)
# Derived from: win2025-core.qcow2 (Base Image)
# ==============================================================================
set -euo pipefail

IMAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../scripts/common.sh
source "${IMAGE_DIR}/../../../scripts/common.sh"

OVERLAY_ONLY=0
for arg in "$@"; do
    if [[ "${arg}" == "--overlay-only" ]]; then
        OVERLAY_ONLY=1
    fi
done

LOG_FILE="${OUTPUT_DIR}/build-rust-gnu.log"
exec > >(tee -a "${LOG_FILE}") 2>&1

log_step "Starting Rust GNU Child Image Build: win2025-core-rust-gnu.qcow2"
check_kvm
ensure_base_image

WORK_QCOW2="${BUILD_DIR}/gnu-work.qcow2"
PAYLOAD_ISO="${BUILD_DIR}/payload-gnu.iso"
PAYLOAD_DIR="${BUILD_DIR}/payload_gnu_root"

# Create CoW overlay disk based on Base image
log_step "[Phase 1/4] Creating transient CoW overlay disk based on win2025-core.qcow2..."
rm -f "${WORK_QCOW2}"
qemu-img create -f qcow2 -b "${BASE_IMAGE}" -F qcow2 "${WORK_QCOW2}"

# Prepare Payload ISO with GNU provision script and pre-fetched offline assets
log_step "[Phase 2/4] Assembling Offline Payload ISO..."
bash "${SCRIPTS_DIR}/fetch-gnu-assets.sh"

rm -rf "${PAYLOAD_DIR}"
mkdir -p "${PAYLOAD_DIR}"

cp "${IMAGE_DIR}/provision.ps1" "${PAYLOAD_DIR}/child-provision.ps1"
touch "${PAYLOAD_DIR}/runner.ready"

log_info "Staging offline assets into payload media..."
cp "${PACKAGES_DIR}/w64devkit.exe" "${PAYLOAD_DIR}/w64devkit.exe"
cp "${PACKAGES_DIR}/vc_redist.x64.exe" "${PAYLOAD_DIR}/vc_redist.x64.exe"
cp "${PACKAGES_DIR}/rustup-init.exe" "${PAYLOAD_DIR}/rustup-init.exe"
cp -r "${PACKAGES_DIR}/cargo-tools" "${PAYLOAD_DIR}/cargo-tools"

if [[ -f "${PACKAGES_DIR}/rust-gnu.tar.gz" ]]; then
    cp "${PACKAGES_DIR}/rust-gnu.tar.gz" "${PAYLOAD_DIR}/rust-gnu.tar.gz"
fi
if [[ -d "${PACKAGES_DIR}/rust-gnu" ]]; then
    cp -r "${PACKAGES_DIR}/rust-gnu" "${PAYLOAD_DIR}/rust-gnu"
fi

make_iso "${PAYLOAD_ISO}" "${PAYLOAD_DIR}" "PROVISION"

# Run QEMU with physical network isolation (-nic none)
log_step "[Phase 3/4] Launching Isolated Offline QEMU Provisioning..."
MONITOR_SOCK="${BUILD_DIR}/qemu-monitor-gnu.sock"
rm -f "${MONITOR_SOCK}"

qemu-system-x86_64 \
    -enable-kvm \
    -m "${MEMORY_MB}" \
    -smp "${CPUS}" \
    -cpu host,hv_relaxed,hv_spinlocks=0x1fff,hv_vapic,hv_time \
    -drive "file=${WORK_QCOW2},if=virtio,format=qcow2,cache=writeback" \
    -drive "file=${PAYLOAD_ISO},media=cdrom,index=1" \
    -nic none \
    -vnc "127.0.0.1:${VNC_PORT}" \
    -display none \
    -monitor "unix:${MONITOR_SOCK},server,nowait" \
    -boot order=c \
    -no-reboot

log_info "VM provisioning completed and cleanly shut down."

# Finalize image
log_step "[Phase 4/4] Finalizing Rust GNU Image..."
if [[ "${OVERLAY_ONLY}" -eq 1 ]]; then
    log_info "Overlay-only mode: Preserving linked CoW layer..."
    mv "${WORK_QCOW2}" "${GNU_IMAGE}"
    # Rebase backing file to relative path for portability
    qemu-img rebase -u -b "win2025-core.qcow2" -F qcow2 "${GNU_IMAGE}" 2>/dev/null || true
else
    convert_and_compress "${WORK_QCOW2}" "${GNU_IMAGE}"
    rm -f "${WORK_QCOW2}"
fi

rm -f "${PAYLOAD_ISO}"
rm -rf "${PAYLOAD_DIR}"

# Generate Metadata JSON
cat << JSON_EOF > "${GNU_METADATA}"
{
  "image": {
    "filename": "$(basename "${GNU_IMAGE}")",
    "path": "${GNU_IMAGE}",
    "format": "qcow2",
    "derived_from": "$(basename "${BASE_IMAGE}")",
    "virtual_size": "${DISK_SIZE}",
    "overlay_only": $([ "${OVERLAY_ONLY}" -eq 1 ] && echo "true" || echo "false"),
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
      "rustup_home": "C:\\\\Users\\\\${ADMIN_USER}\\\\.rustup",
      "cargo_binstall": true,
      "installed_tools": [
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
      ]
    },
    "c_cpp": {
      "toolchain": "w64devkit",
      "flavor": "MinGW-w64",
      "path": "C:\\\\tools\\\\w64devkit\\\\bin"
    },
    "vc_redist": {
      "installed": true,
      "version": "2015-2022 x64"
    }
  },
  "drivers": {
    "virtio_guest_tools": true,
    "qemu_guest_agent": true
  }
}
JSON_EOF

log_step "Rust GNU Image Build Succeeded!"
echo "==> GNU QCOW2:  ${GNU_IMAGE}"
echo "==> Metadata:   ${GNU_METADATA}"
qemu-img info "${GNU_IMAGE}"
