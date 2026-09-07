#!/usr/bin/env bash
# ==============================================================================
# Script: build.sh
# Description: Unified Orchestrator for Windows Server 2025 Core Tree Images
# Usage: ./scripts/build.sh [all|base|gnu|msvc] [--overlay-only]
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

TARGET="all"
EXTRA_ARGS=()

for arg in "$@"; do
    case "${arg}" in
        all|base|gnu|msvc)
            TARGET="${arg}"
            ;;
        --overlay-only)
            EXTRA_ARGS+=("${arg}")
            ;;
        -h|--help)
            echo "Usage: $0 [all|base|gnu|msvc] [--overlay-only]"
            echo ""
            echo "Targets:"
            echo "  all    : Build base image, then both rust-gnu and rust-msvc images (default)"
            echo "  base   : Build root image only (win2025-core.qcow2)"
            echo "  gnu    : Build Rust GNU child image (win2025-core-rust-gnu.qcow2)"
            echo "  msvc   : Build Rust MSVC child image (win2025-core-rust-msvc.qcow2)"
            echo ""
            echo "Options:"
            echo "  --overlay-only : Keep lightweight linked CoW overlay instead of flattening"
            exit 0
            ;;
        *)
            log_error "Unknown argument: ${arg}"
            echo "Run '$0 --help' for usage."
            exit 1
            ;;
    esac
done

echo "====================================================================="
echo "==> Windows Server 2025 Core Image Tree Builder"
echo "    Target: ${TARGET}"
echo "    Options: ${EXTRA_ARGS[*]:-(none)}"
echo "====================================================================="

check_kvm

case "${TARGET}" in
    base)
        bash "${BASE_DIR}/build.sh"
        ;;
    gnu)
        ensure_base_image
        bash "${GNU_DIR}/build.sh" "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"
        ;;
    msvc)
        ensure_base_image
        bash "${MSVC_DIR}/build.sh" "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"
        ;;
    all)
        log_step "Step 1/3: Checking / Building Base Image (win2025-core.qcow2)..."
        ensure_base_image

        log_step "Step 2/3: Building Rust GNU Child Image (win2025-core-rust-gnu.qcow2)..."
        bash "${GNU_DIR}/build.sh" "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"

        log_step "Step 3/3: Building Rust MSVC Child Image (win2025-core-rust-msvc.qcow2)..."
        bash "${MSVC_DIR}/build.sh" "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"

        log_step "All Images in Tree Built Successfully!"
        echo "Outputs available in ${OUTPUT_DIR}:"
        ls -lh "${OUTPUT_DIR}"/*.qcow2 "${OUTPUT_DIR}"/*.json 2>/dev/null || true
        ;;
esac
