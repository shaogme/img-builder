#!/usr/bin/env bash
# ==============================================================================
# Script: scripts/fetch-gnu-assets.sh
# Description: Pre-fetch all dependencies for Rust GNU child image on host
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=fetch-common.sh
source "${SCRIPT_DIR}/fetch-common.sh"

log_step "Pre-fetching Rust GNU Toolchain Assets on Host..."

# 1. vc_redist
fetch_vc_redist

# 2. rustup-init
fetch_rustup_init

# 3. cargo-tools
fetch_cargo_tools

# 4. w64devkit
W64_TARGET="${PACKAGES_DIR}/w64devkit.exe"
if [[ -f "${W64_TARGET}" ]] && [[ $(stat -c%s "${W64_TARGET}") -gt 10000000 ]]; then
    log_info "w64devkit already cached at ${W64_TARGET} ($(stat -c%s "${W64_TARGET}") bytes)."
else
    log_info "Resolving latest w64devkit release..."
    EFF_URL=$(curl -sIL -o /dev/null -w "%{url_effective}" https://github.com/skeeto/w64devkit/releases/latest || true)
    TAG="${EFF_URL##*/}"
    W64_VER="${TAG#v}"

    if [[ -z "${W64_VER}" ]]; then
        W64_TAG=$(curl -s https://api.github.com/repos/skeeto/w64devkit/releases/latest | jq -r '.tag_name // empty' || true)
        W64_VER="${W64_TAG#v}"
    fi

    if [[ -z "${W64_VER}" ]]; then
        log_error "CRITICAL: Unable to resolve latest w64devkit version from GitHub."
        exit 1
    fi

    W64_URL="https://github.com/skeeto/w64devkit/releases/download/v${W64_VER}/w64devkit-x64-${W64_VER}.7z.exe"
    W64_TMP="${W64_TARGET}.tmp"
    log_info "Downloading w64devkit v${W64_VER}..."
    curl -fsSL --retry 3 --retry-delay 3 "${W64_URL}" -o "${W64_TMP}"
    mv "${W64_TMP}" "${W64_TARGET}"
    log_info "Cached w64devkit successfully."
fi

# 5. Rust GNU Toolchain
GNU_DEST="${PACKAGES_DIR}/rust-gnu"
GNU_TAR="${PACKAGES_DIR}/rust-stable-x86_64-pc-windows-gnu.tar.gz"

if [[ -d "${GNU_DEST}" ]] && [[ -f "${GNU_DEST}/bin/rustc.exe" ]]; then
    log_info "Rust GNU toolchain already cached at ${GNU_DEST}."
else
    log_info "Resolving latest Rust stable (x86_64-pc-windows-gnu) URL..."
    GNU_URL=$(resolve_rust_channel_url "x86_64-pc-windows-gnu")
    log_info "Resolved URL: ${GNU_URL}"

    if [[ ! -f "${GNU_TAR}" ]] || [[ $(stat -c%s "${GNU_TAR}") -lt 50000000 ]]; then
        log_info "Downloading Rust GNU tarball..."
        curl -fsSL --retry 3 --retry-delay 5 "${GNU_URL}" -o "${GNU_TAR}.tmp"
        mv "${GNU_TAR}.tmp" "${GNU_TAR}"
    fi

    install_rust_tarball "${GNU_TAR}" "${GNU_DEST}" "x86_64-pc-windows-gnu"
fi

log_step "All Rust GNU Assets Successfully Pre-fetched!"
ls -lh "${PACKAGES_DIR}/w64devkit.exe" "${PACKAGES_DIR}/vc_redist.x64.exe" "${PACKAGES_DIR}/rustup-init.exe"
ls -d "${PACKAGES_DIR}/rust-gnu" "${PACKAGES_DIR}/cargo-tools"
