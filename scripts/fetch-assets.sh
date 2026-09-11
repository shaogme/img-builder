#!/usr/bin/env bash
# ==============================================================================
# Script: scripts/fetch-assets.sh
# Description: Unified host asset pre-fetcher for all images
# Usage: ./scripts/fetch-assets.sh [all|gnu|msvc|common|openssh]
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=fetch-common.sh
source "${SCRIPT_DIR}/fetch-common.sh"

TARGET="${1:-all}"

case "${TARGET}" in
    common)
        log_step "Fetching common assets..."
        fetch_vc_redist
        fetch_rustup_init
        fetch_cargo_tools
        fetch_vs_bootstrapper
        ;;
    openssh)
        log_step "Fetching offline OpenSSH package..."
        fetch_win32_openssh
        ;;
    gnu)
        bash "${SCRIPT_DIR}/fetch-gnu-assets.sh"
        ;;
    msvc)
        bash "${SCRIPT_DIR}/fetch-msvc-assets.sh"
        ;;
    all)
        log_step "Fetching all host-side assets for all image targets..."
        fetch_win32_openssh
        bash "${SCRIPT_DIR}/fetch-gnu-assets.sh"
        bash "${SCRIPT_DIR}/fetch-msvc-assets.sh"
        log_step "All assets pre-fetched successfully into ${PACKAGES_DIR}."
        ;;
    *)
        log_error "Unknown target: ${TARGET}"
        echo "Usage: $0 [all|gnu|msvc|common|openssh]"
        exit 1
        ;;
esac
