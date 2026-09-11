#!/usr/bin/env bash
# ==============================================================================
# Script: scripts/fetch-msvc-assets.sh
# Description: Pre-fetch all host-side dependencies for Rust MSVC child image
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=fetch-common.sh
source "${SCRIPT_DIR}/fetch-common.sh"

log_step "Pre-fetching Rust MSVC Host-side Assets..."

# 1. vc_redist
fetch_vc_redist

# 2. vs_BuildTools bootstrapper
fetch_vs_bootstrapper

# 3. rustup-init
fetch_rustup_init

# 4. cargo-tools
fetch_cargo_tools

# 5. Rust MSVC Toolchain
MSVC_DEST="${PACKAGES_DIR}/rust-msvc"
MSVC_TAR="${PACKAGES_DIR}/rust-stable-x86_64-pc-windows-msvc.tar.gz"

if [[ -d "${MSVC_DEST}" ]] && [[ -f "${MSVC_DEST}/bin/rustc.exe" ]]; then
    log_info "Rust MSVC toolchain already cached at ${MSVC_DEST}."
else
    log_info "Resolving latest Rust stable (x86_64-pc-windows-msvc) URL..."
    MSVC_URL=$(resolve_rust_channel_url "x86_64-pc-windows-msvc")
    log_info "Resolved URL: ${MSVC_URL}"

    if [[ ! -f "${MSVC_TAR}" ]] || [[ $(stat -c%s "${MSVC_TAR}") -lt 50000000 ]]; then
        log_info "Downloading Rust MSVC tarball..."
        curl -fsSL --retry 3 --retry-delay 5 "${MSVC_URL}" -o "${MSVC_TAR}.tmp"
        mv "${MSVC_TAR}.tmp" "${MSVC_TAR}"
    fi

    install_rust_tarball "${MSVC_TAR}" "${MSVC_DEST}" "x86_64-pc-windows-msvc"
fi

# 6. Ensure offline Microsoft certificates are present
MSVC_CERT_DIR="${WORKSPACE_DIR}/images/rust/msvc/certificates"
mkdir -p "${MSVC_CERT_DIR}"
if [[ ! -f "${MSVC_CERT_DIR}/Microsoft_Windows_Code_Signing_PCA_2024.crt" ]]; then
    log_info "Downloading Microsoft Windows Code Signing PCA 2024 certificate..."
    curl -fsSL -k "https://www.microsoft.com/pkiops/certs/Microsoft%20Windows%20Code%20Signing%20PCA%202024.crt" -o "${MSVC_CERT_DIR}/Microsoft_Windows_Code_Signing_PCA_2024.crt"
fi
if [[ ! -f "${MSVC_CERT_DIR}/Microsoft_Code_Signing_PCA_2024.crt" ]]; then
    log_info "Downloading Microsoft Code Signing PCA 2024 certificate..."
    curl -fsSL -k "https://www.microsoft.com/pkiops/certs/Microsoft%20Code%20Signing%20PCA%202024.crt" -o "${MSVC_CERT_DIR}/Microsoft_Code_Signing_PCA_2024.crt"
fi
if [[ ! -f "${MSVC_CERT_DIR}/MicCodSigPCA2011_2011-07-08.crt" ]]; then
    log_info "Downloading Microsoft Code Signing PCA 2011 certificate..."
    curl -fsSL -k "https://www.microsoft.com/pkiops/certs/MicCodSigPCA2011_2011-07-08.crt" -o "${MSVC_CERT_DIR}/MicCodSigPCA2011_2011-07-08.crt"
fi
if [[ ! -f "${MSVC_CERT_DIR}/MicWinProPCA2011_2011-10-19.crt" ]]; then
    log_info "Downloading Microsoft Windows Production PCA 2011 certificate..."
    curl -fsSL -k "https://www.microsoft.com/pkiops/certs/MicWinProPCA2011_2011-10-19.crt" -o "${MSVC_CERT_DIR}/MicWinProPCA2011_2011-10-19.crt"
fi

log_step "All Rust MSVC Host-side Assets Successfully Pre-fetched!"
ls -lh "${PACKAGES_DIR}/vs_BuildTools.exe" "${PACKAGES_DIR}/vc_redist.x64.exe" "${PACKAGES_DIR}/rustup-init.exe"
ls -d "${PACKAGES_DIR}/rust-msvc" "${PACKAGES_DIR}/cargo-tools"

