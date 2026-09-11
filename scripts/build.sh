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
        all|base|gnu|msvc|layout|prefetch|fetch)
            TARGET="${arg}"
            ;;
        --overlay-only)
            EXTRA_ARGS+=("${arg}")
            ;;
        -h|--help)
            echo "Usage: $0 [all|base|gnu|msvc|layout|prefetch] [--overlay-only]"
            echo ""
            echo "Targets:"
            echo "  all      : Build base image, prefetch assets, generate VS layout, then build child images (default)"
            echo "  base     : Build root image only (win2025-core.qcow2)"
            echo "  gnu      : Build Rust GNU child image (win2025-core-rust-gnu.qcow2)"
            echo "  msvc     : Build Rust MSVC child image (win2025-core-rust-msvc.qcow2)"
            echo "  layout   : Generate offline VS Build Tools layout disk via Base VM (vs_layout.qcow2)"
            echo "  prefetch : Pre-fetch all dependencies and compilers to host cache"
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
echo "==> Windows Server 2025 Core Image Tree Builder (Offline Mode)"
echo "    Target: ${TARGET}"
echo "    Options: ${EXTRA_ARGS[*]:-(none)}"
echo "====================================================================="

check_kvm

case "${TARGET}" in
    base)
        bash "${BASE_DIR}/build.sh"
        ;;
    prefetch|fetch)
        bash "${SCRIPTS_DIR}/fetch-assets.sh" all
        ;;
    layout)
        ensure_base_image
        bash "${MSVC_DIR}/fetch-layout.sh"
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
        log_step "Step 1/5: Checking / Building Base Image (win2025-core.qcow2)..."
        ensure_base_image

        log_step "Step 2/5: Pre-fetching All Host-side Dependencies & Toolchains..."
        bash "${SCRIPTS_DIR}/fetch-assets.sh" all

        log_step "Step 3/5: Ensuring Visual Studio Build Tools Offline Layout Disk..."
        bash "${MSVC_DIR}/fetch-layout.sh"

        log_step "Step 4/5: Building Rust GNU Child Image (100% Offline, -nic none)..."
        bash "${GNU_DIR}/build.sh" "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"

        log_step "Step 5/5: Building Rust MSVC Child Image (100% Offline, -nic none)..."
        bash "${MSVC_DIR}/build.sh" "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"

        log_step "All Images in Tree Built Successfully!"
        echo "Outputs available in ${OUTPUT_DIR}:"
        ls -lh "${OUTPUT_DIR}"/*.qcow2 "${OUTPUT_DIR}"/*.json 2>/dev/null || true
        ;;
esac
