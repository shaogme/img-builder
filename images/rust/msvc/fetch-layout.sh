#!/usr/bin/env bash
# ==============================================================================
# Script: images/rust/msvc/fetch-layout.sh
# Description: Base-image-driven Visual Studio Build Tools offline layout generator
# Output: packages/vs_layout.qcow2 (12GB sparse QCOW2 with full offline VS layout)
# ==============================================================================
set -euo pipefail

IMAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../scripts/common.sh
source "${IMAGE_DIR}/../../../scripts/common.sh"
# shellcheck source=../../../scripts/fetch-common.sh
source "${IMAGE_DIR}/../../../scripts/fetch-common.sh"

LOG_FILE="${OUTPUT_DIR}/fetch-vs-layout.log"
exec > >(tee -a "${LOG_FILE}") 2>&1

log_step "Starting Visual Studio Build Tools Offline Layout Generator (Base VM Driven)"

# Check if layout disk already exists
if [[ -f "${VS_LAYOUT_QCOW2}" ]]; then
    ACTUAL_SIZE=$(qemu-img info --output=json "${VS_LAYOUT_QCOW2}" 2>/dev/null | jq -r '."actual-size" // 0' || echo "0")
    if [[ "${ACTUAL_SIZE}" -gt 1073741824 ]]; then
        log_info "Valid VS Build Tools offline layout disk already exists at ${VS_LAYOUT_QCOW2} (actual size: $(( ACTUAL_SIZE / 1048576 )) MB)."
        # Ensure build directory symlink
        ln -sf "${VS_LAYOUT_QCOW2}" "${BUILD_DIR}/vs_layout.qcow2"
        exit 0
    fi
fi

if [[ -f "${BUILD_DIR}/vs_layout.qcow2" ]]; then
    ACTUAL_SIZE=$(qemu-img info --output=json "${BUILD_DIR}/vs_layout.qcow2" 2>/dev/null | jq -r '."actual-size" // 0' || echo "0")
    if [[ "${ACTUAL_SIZE}" -gt 1073741824 ]]; then
        log_info "Found valid VS layout in build directory, moving to packages cache..."
        mv "${BUILD_DIR}/vs_layout.qcow2" "${VS_LAYOUT_QCOW2}"
        ln -sf "${VS_LAYOUT_QCOW2}" "${BUILD_DIR}/vs_layout.qcow2"
        exit 0
    fi
fi

check_kvm
ensure_base_image

# 1. Pre-fetch vs_BuildTools bootstrapper on host
log_step "[Phase 1/4] Ensuring vs_BuildTools bootstrapper is cached on host..."
fetch_vs_bootstrapper

# 2. Allocate 12GB sparse layout disk
log_step "[Phase 2/4] Allocating 12GB sparse layout QCOW2 disk..."
rm -f "${VS_LAYOUT_QCOW2}" "${BUILD_DIR}/vs_layout.qcow2"
qemu-img create -f qcow2 "${VS_LAYOUT_QCOW2}" 12G

# 3. Create transient CoW overlay for Base VM and assemble payload ISO
log_step "[Phase 3/4] Assembling transient VM environment and downloader payload ISO..."
WORK_QCOW2="${BUILD_DIR}/downloader-work.qcow2"
rm -f "${WORK_QCOW2}"
qemu-img create -f qcow2 -b "${BASE_IMAGE}" -F qcow2 "${WORK_QCOW2}"

PAYLOAD_DIR="${BUILD_DIR}/downloader_payload_root"
PAYLOAD_ISO="${BUILD_DIR}/downloader-payload.iso"
rm -rf "${PAYLOAD_DIR}" "${PAYLOAD_ISO}"
mkdir -p "${PAYLOAD_DIR}"

cp "${IMAGE_DIR}/download-layout.ps1" "${PAYLOAD_DIR}/child-provision.ps1"
touch "${PAYLOAD_DIR}/runner.ready"
cp "${PACKAGES_DIR}/vs_BuildTools.exe" "${PAYLOAD_DIR}/vs_BuildTools.exe"

make_iso "${PAYLOAD_ISO}" "${PAYLOAD_DIR}" "PROVISION"

# 4. Launch QEMU with network access to download components
log_step "[Phase 4/4] Launching transient Base VM to create VS Build Tools offline layout..."
MONITOR_SOCK="${BUILD_DIR}/qemu-monitor-layout.sock"
rm -f "${MONITOR_SOCK}"

# VM Disk Map:
# - virtio index 0: WORK_QCOW2 (system disk, transient CoW based on Base)
# - virtio index 1: VS_LAYOUT_QCOW2 (target layout disk to be formatted and filled)
# - cdrom index 1:  PAYLOAD_ISO (downloader script and bootstrapper)
qemu-system-x86_64 \
    -enable-kvm \
    -m "${MEMORY_MB}" \
    -smp "${CPUS}" \
    -cpu host,hv_relaxed,hv_spinlocks=0x1fff,hv_vapic,hv_time \
    -drive "file=${WORK_QCOW2},if=virtio,format=qcow2,cache=writeback" \
    -drive "file=${VS_LAYOUT_QCOW2},if=virtio,format=qcow2,cache=writeback" \
    -drive "file=${PAYLOAD_ISO},media=cdrom,index=1" \
    -netdev user,id=net0 \
    -device virtio-net-pci,netdev=net0 \
    -vnc "127.0.0.1:${VNC_PORT}" \
    -display none \
    -monitor "unix:${MONITOR_SOCK},server,nowait" \
    -boot order=c \
    -no-reboot &
QEMU_PID=$!

log_info "Transient downloader VM started (PID: ${QEMU_PID}). Monitoring download progress..."

START_TIME=$(date +%s)
while kill -0 "${QEMU_PID}" 2>/dev/null; do
    sleep 15
    NOW=$(date +%s)
    ELAPSED=$(( (NOW - START_TIME) / 60 ))
    ACTUAL_SIZE=$(qemu-img info --output=json "${VS_LAYOUT_QCOW2}" 2>/dev/null | jq -r '."actual-size" // 0' || echo "0")
    ACTUAL_MB=$(( ACTUAL_SIZE / 1048576 ))
    log_info "[${ELAPSED}m elapsed] VS layout disk allocated: ${ACTUAL_MB} MB..."
done

wait "${QEMU_PID}" 2>/dev/null || true
log_info "Downloader VM exited."

# Verify resulting layout disk
if [[ ! -f "${VS_LAYOUT_QCOW2}" ]]; then
    log_error "CRITICAL: Expected layout disk ${VS_LAYOUT_QCOW2} not found!"
    exit 1
fi

ACTUAL_SIZE=$(qemu-img info --output=json "${VS_LAYOUT_QCOW2}" | jq -r '."actual-size" // 0')
if [[ "${ACTUAL_SIZE}" -lt 500000000 ]]; then
    log_error "CRITICAL: VS layout disk size (${ACTUAL_SIZE} bytes) is suspiciously small! Download may have failed."
    log_warn "Preserving transient downloader disk ${WORK_QCOW2} for diagnosis."
    exit 1
fi

# Clean up transient VM resources on success
rm -f "${WORK_QCOW2}" "${PAYLOAD_ISO}" "${MONITOR_SOCK}"
rm -rf "${PAYLOAD_DIR}"

ln -sf "${VS_LAYOUT_QCOW2}" "${BUILD_DIR}/vs_layout.qcow2"

log_step "VS Build Tools Offline Layout Disk Created Successfully!"
echo "==> Layout Disk: ${VS_LAYOUT_QCOW2}"
qemu-img info "${VS_LAYOUT_QCOW2}"
