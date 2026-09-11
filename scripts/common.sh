#!/usr/bin/env bash
# ==============================================================================
# Script: common.sh
# Description: Common definitions and helper functions for image builder pipeline
# ==============================================================================
set -euo pipefail

WORKSPACE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ISO_DIR="${WORKSPACE_DIR}/ISO"
BUILD_DIR="${WORKSPACE_DIR}/build"
OUTPUT_DIR="${WORKSPACE_DIR}/output"
SCRIPTS_DIR="${WORKSPACE_DIR}/scripts"
IMAGES_DIR="${WORKSPACE_DIR}/images"

BASE_DIR="${IMAGES_DIR}/base"
GNU_DIR="${IMAGES_DIR}/rust/gnu"
MSVC_DIR="${IMAGES_DIR}/rust/msvc"

WIN_ISO="${ISO_DIR}/26100.1_SERVERSTANDARD_X64_EN-US.ISO"
VIRTIO_ISO="${ISO_DIR}/virtio-win-0.1.302.iso"

BASE_IMAGE="${OUTPUT_DIR}/win2025-core.qcow2"
BASE_METADATA="${OUTPUT_DIR}/win2025-core.json"

GNU_IMAGE="${OUTPUT_DIR}/win2025-core-rust-gnu.qcow2"
GNU_METADATA="${OUTPUT_DIR}/win2025-core-rust-gnu.json"

MSVC_IMAGE="${OUTPUT_DIR}/win2025-core-rust-msvc.qcow2"
MSVC_METADATA="${OUTPUT_DIR}/win2025-core-rust-msvc.json"

DISK_SIZE="64G"
MEMORY_MB="8192"
CPUS="4"
VNC_PORT="1" # 127.0.0.1:5901

ADMIN_USER="Administrator"
ADMIN_PASS="Admin1234!"

PACKAGES_DIR="${WORKSPACE_DIR}/packages"
VS_LAYOUT_QCOW2="${PACKAGES_DIR}/vs_layout.qcow2"

mkdir -p "${OUTPUT_DIR}" "${BUILD_DIR}" "${PACKAGES_DIR}"

log_info() {
    echo -e "\033[1;34m[INFO]\033[0m $*"
}

log_step() {
    echo -e "\n\033[1;36m==> $*\033[0m"
}

log_warn() {
    echo -e "\033[1;33m[WARN]\033[0m $*" >&2
}

log_error() {
    echo -e "\033[1;31m[ERROR]\033[0m $*" >&2
}

check_kvm() {
    if [[ ! -c /dev/kvm ]]; then
        log_error "KVM hardware acceleration not available (/dev/kvm missing)!"
        exit 1
    fi
}

check_base_inputs() {
    check_kvm
    if [[ ! -f "${WIN_ISO}" ]]; then
        log_error "Windows ISO not found at ${WIN_ISO}"
        exit 1
    fi
    if [[ ! -f "${VIRTIO_ISO}" ]]; then
        log_error "VirtIO ISO not found at ${VIRTIO_ISO}"
        exit 1
    fi
}

ensure_base_image() {
    if [[ ! -f "${BASE_IMAGE}" ]]; then
        log_warn "Base image ${BASE_IMAGE} not found! Triggering base image build first..."
        bash "${BASE_DIR}/build.sh"
    fi
}

make_iso() {
    local out_iso="$1"
    local src_dir="$2"
    local vol_label="${3:-OEMDRV}"

    # Convert line endings for Windows scripts if unix2dos is installed
    if command -v unix2dos >/dev/null 2>&1; then
        find "${src_dir}" -maxdepth 2 -type f \( -name "*.xml" -o -name "*.ps1" -o -name "*.cfg" \) -exec unix2dos -q {} + 2>/dev/null || true
    fi

    rm -f "${out_iso}"
    genisoimage -quiet -l -o "${out_iso}" -J -r -V "${vol_label}" "${src_dir}"
    log_info "Generated ISO: ${out_iso}"
}

convert_and_compress() {
    local src_qcow2="$1"
    local dst_qcow2="$2"
    log_step "Compressing and finalizing QCOW2 image: $(basename "${dst_qcow2}")..."
    rm -f "${dst_qcow2}"
    qemu-img convert -f qcow2 -O qcow2 -c -p "${src_qcow2}" "${dst_qcow2}"
    log_info "Generated compressed image: ${dst_qcow2}"
    ls -lh "${dst_qcow2}"
}
