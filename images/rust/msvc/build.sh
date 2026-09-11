#!/usr/bin/env bash
# ==============================================================================
# Script: images/rust/msvc/build.sh
# Description: Automated Rust MSVC Image Builder (win2025-core-rust-msvc.qcow2)
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

LOG_FILE="${OUTPUT_DIR}/build-rust-msvc.log"
exec > >(tee -a "${LOG_FILE}") 2>&1

log_step "Starting Rust MSVC Child Image Build: win2025-core-rust-msvc.qcow2"
check_kvm
ensure_base_image

WORK_QCOW2="${BUILD_DIR}/msvc-work.qcow2"
PAYLOAD_ISO="${BUILD_DIR}/payload-msvc.iso"
PAYLOAD_DIR="${BUILD_DIR}/payload_msvc_root"

# Create CoW overlay disk based on Base image
log_step "[Phase 1/4] Creating transient CoW overlay disk based on win2025-core.qcow2..."
rm -f "${WORK_QCOW2}"
qemu-img create -f qcow2 -b "${BASE_IMAGE}" -F qcow2 "${WORK_QCOW2}"

# Ensure offline VS Build Tools layout disk exists
log_step "[Phase 1.5/4] Ensuring VS Build Tools offline layout disk is ready..."
if [[ ! -f "${VS_LAYOUT_QCOW2}" ]] && [[ ! -f "${BUILD_DIR}/vs_layout.qcow2" ]]; then
    log_warn "VS Build Tools layout disk not found. Generating layout via Base VM..."
    bash "${IMAGE_DIR}/fetch-layout.sh"
fi

if [[ -f "${BUILD_DIR}/vs_layout.qcow2" ]] && [[ ! -f "${VS_LAYOUT_QCOW2}" ]]; then
    VS_LAYOUT_QCOW2="${BUILD_DIR}/vs_layout.qcow2"
fi

# Prepare Payload ISO with MSVC provision script and pre-fetched offline assets
log_step "[Phase 2/4] Assembling Offline Payload ISO..."
bash "${SCRIPTS_DIR}/fetch-msvc-assets.sh"

rm -rf "${PAYLOAD_DIR}"
mkdir -p "${PAYLOAD_DIR}"

cp "${IMAGE_DIR}/provision.ps1" "${PAYLOAD_DIR}/child-provision.ps1"
touch "${PAYLOAD_DIR}/runner.ready"

log_info "Staging offline assets into MSVC payload media..."
cp "${PACKAGES_DIR}/vc_redist.x64.exe" "${PAYLOAD_DIR}/vc_redist.x64.exe"
cp "${PACKAGES_DIR}/rustup-init.exe" "${PAYLOAD_DIR}/rustup-init.exe"
cp -r "${PACKAGES_DIR}/cargo-tools" "${PAYLOAD_DIR}/cargo-tools"

if [[ -f "${PACKAGES_DIR}/rust-msvc.tar.gz" ]]; then
    cp "${PACKAGES_DIR}/rust-msvc.tar.gz" "${PAYLOAD_DIR}/rust-msvc.tar.gz"
fi
if [[ -d "${PACKAGES_DIR}/rust-msvc" ]]; then
    cp -r "${PACKAGES_DIR}/rust-msvc" "${PAYLOAD_DIR}/rust-msvc"
fi

if [[ -d "${IMAGE_DIR}/certificates" ]]; then
    log_info "Staging offline Microsoft certificates into MSVC payload media..."
    cp -r "${IMAGE_DIR}/certificates" "${PAYLOAD_DIR}/certificates"
fi

make_iso "${PAYLOAD_ISO}" "${PAYLOAD_DIR}" "PROVISION"

# Run QEMU with physical network isolation (-nic none) and dual VirtIO drives
log_step "[Phase 3/4] Launching Isolated Offline MSVC QEMU Provisioning..."
MONITOR_SOCK="${BUILD_DIR}/qemu-monitor-msvc.sock"
rm -f "${MONITOR_SOCK}"

LAYOUT_WORK="${BUILD_DIR}/msvc-layout-work.qcow2"
rm -f "${LAYOUT_WORK}"
qemu-img create -f qcow2 -b "${VS_LAYOUT_QCOW2}" -F qcow2 "${LAYOUT_WORK}"

qemu-system-x86_64 \
    -enable-kvm \
    -m "${MEMORY_MB}" \
    -smp "${CPUS}" \
    -cpu host,hv_relaxed,hv_spinlocks=0x1fff,hv_vapic,hv_time \
    -drive "file=${WORK_QCOW2},if=virtio,format=qcow2,cache=writeback" \
    -drive "file=${LAYOUT_WORK},if=virtio,format=qcow2,cache=writeback" \
    -drive "file=${PAYLOAD_ISO},media=cdrom,index=1" \
    -nic none \
    -vnc "127.0.0.1:${VNC_PORT}" \
    -display none \
    -monitor "unix:${MONITOR_SOCK},server,nowait" \
    -boot order=c \
    -no-reboot

rm -f "${LAYOUT_WORK}"
log_info "VM provisioning completed and cleanly shut down."

# Finalize image
log_step "[Phase 4/4] Finalizing Rust MSVC Image..."
if [[ "${OVERLAY_ONLY}" -eq 1 ]]; then
    log_info "Overlay-only mode: Preserving linked CoW layer..."
    mv "${WORK_QCOW2}" "${MSVC_IMAGE}"
    # Rebase backing file to relative path for portability
    qemu-img rebase -u -b "win2025-core.qcow2" -F qcow2 "${MSVC_IMAGE}" 2>/dev/null || true
else
    convert_and_compress "${WORK_QCOW2}" "${MSVC_IMAGE}"
    rm -f "${WORK_QCOW2}"
fi

rm -f "${PAYLOAD_ISO}"
rm -rf "${PAYLOAD_DIR}"

# Generate Metadata JSON
cat << JSON_EOF > "${MSVC_METADATA}"
{
  "image": {
    "filename": "$(basename "${MSVC_IMAGE}")",
    "path": "${MSVC_IMAGE}",
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
      "host_triple": "x86_64-pc-windows-msvc",
      "channel": "stable",
      "msvc_dependent": true,
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
      "toolchain": "Visual Studio 2022 Build Tools",
      "flavor": "MSVC",
      "install_path": "C:\\\\BuildTools",
      "tools": ["cl.exe", "link.exe", "vswhere.exe"]
    }
  },
  "drivers": {
    "virtio_guest_tools": true,
    "qemu_guest_agent": true
  }
}
JSON_EOF

log_step "Rust MSVC Image Build Succeeded!"
echo "==> MSVC QCOW2: ${MSVC_IMAGE}"
echo "==> Metadata:   ${MSVC_METADATA}"
qemu-img info "${MSVC_IMAGE}"
