#!/usr/bin/env bash
# ==============================================================================
# Script: scripts/fetch-common.sh
# Description: Common asset fetching routines for offline builds
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

export SSL_CERT_FILE="${NIX_SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}"

fetch_vc_redist() {
    local target="${PACKAGES_DIR}/vc_redist.x64.exe"
    if [[ -f "${target}" ]] && [[ -s "${target}" ]] && [[ $(stat -c%s "${target}") -gt 1000000 ]]; then
        log_info "vc_redist.x64.exe already cached at ${target} ($(stat -c%s "${target}") bytes)."
        return 0
    fi
    log_info "Fetching vc_redist.x64.exe from Microsoft CDN..."
    local tmp="${target}.tmp"
    curl -fsSL --retry 3 --retry-delay 3 "https://aka.ms/vs/17/release/vc_redist.x64.exe" -o "${tmp}"
    mv "${tmp}" "${target}"
    log_info "Cached vc_redist.x64.exe successfully."
}

fetch_vs_bootstrapper() {
    local target="${PACKAGES_DIR}/vs_BuildTools.exe"
    if [[ -f "${target}" ]] && [[ -s "${target}" ]] && [[ $(stat -c%s "${target}") -gt 1000000 ]]; then
        log_info "vs_BuildTools.exe already cached at ${target} ($(stat -c%s "${target}") bytes)."
        return 0
    fi
    log_info "Fetching vs_BuildTools.exe from Microsoft CDN..."
    local tmp="${target}.tmp"
    curl -fsSL --retry 3 --retry-delay 3 "https://aka.ms/vs/17/release/vs_BuildTools.exe" -o "${tmp}"
    mv "${tmp}" "${target}"
    log_info "Cached vs_BuildTools.exe successfully."
}

fetch_rustup_init() {
    local target="${PACKAGES_DIR}/rustup-init.exe"
    if [[ -f "${target}" ]] && [[ -s "${target}" ]] && [[ $(stat -c%s "${target}") -gt 1000000 ]]; then
        log_info "rustup-init.exe already cached at ${target} ($(stat -c%s "${target}") bytes)."
        return 0
    fi
    log_info "Fetching rustup-init.exe..."
    local tmp="${target}.tmp"
    curl -fsSL --retry 3 --retry-delay 3 "https://win.rustup.rs/x86_64" -o "${tmp}"
    mv "${tmp}" "${target}"
    log_info "Cached rustup-init.exe successfully."
}

fetch_win32_openssh() {
    local target_zip="${PACKAGES_DIR}/OpenSSH-Win64.zip"
    local target_dir="${PACKAGES_DIR}/openssh"
    if [[ -d "${target_dir}" ]] && [[ -f "${target_dir}/install-sshd.ps1" ]]; then
        log_info "Win32-OpenSSH already cached at ${target_dir}."
        return 0
    fi
    log_info "Fetching Win32-OpenSSH from PowerShell GitHub releases..."
    curl -fsSL --retry 3 --retry-delay 3 \
        "https://github.com/PowerShell/Win32-OpenSSH/releases/latest/download/OpenSSH-Win64.zip" \
        -o "${target_zip}"
    
    local tmp_dir="${BUILD_DIR}/openssh_extract_$$"
    rm -rf "${tmp_dir}" "${target_dir}"
    mkdir -p "${tmp_dir}"
    unzip -q "${target_zip}" -d "${tmp_dir}"
    mkdir -p "${target_dir}"
    cp -r "${tmp_dir}"/OpenSSH-Win64/* "${target_dir}/"
    rm -rf "${tmp_dir}"
    log_info "Cached Win32-OpenSSH successfully."
}

fetch_cargo_tools() {
    local tools_dir="${PACKAGES_DIR}/cargo-tools"
    mkdir -p "${tools_dir}"

    local required_bins=(
        "sccache.exe"
        "cargo-nextest.exe"
        "cargo-sweep.exe"
        "cargo-geiger.exe"
        "cargo-audit.exe"
        "cargo-flamegraph.exe"
        "samply.exe"
        "cargo-asm.exe"
        "cargo-expand.exe"
        "cargo-bloat.exe"
        "cargo-binstall.exe"
    )

    local all_present=1
    for b in "${required_bins[@]}"; do
        if [[ ! -f "${tools_dir}/${b}" ]] || [[ $(stat -c%s "${tools_dir}/${b}") -lt 50000 ]]; then
            all_present=0
            break
        fi
    done

    if [[ "${all_present}" -eq 1 ]]; then
        log_info "All 10 Cargo tools and cargo-binstall already cached at ${tools_dir}."
        return 0
    fi

    log_info "Fetching cargo-binstall for Windows..."
    local binstall_zip="${PACKAGES_DIR}/cargo-binstall.zip"
    curl -fsSL --retry 3 --retry-delay 3 \
        "https://github.com/cargo-bins/cargo-binstall/releases/latest/download/cargo-binstall-x86_64-pc-windows-msvc.zip" \
        -o "${binstall_zip}"
    unzip -q -o "${binstall_zip}" -d "${tools_dir}"
    rm -f "${binstall_zip}"

    log_info "Fetching 10 Cargo tools using cargo-binstall for x86_64-pc-windows-msvc..."
    cargo-binstall --no-confirm --no-track \
        --targets x86_64-pc-windows-msvc \
        --install-path "${tools_dir}" \
        sccache \
        cargo-nextest \
        cargo-sweep \
        cargo-geiger \
        cargo-audit \
        flamegraph \
        samply \
        cargo-show-asm \
        cargo-expand \
        cargo-bloat

    # Verify all tools
    for b in "${required_bins[@]}"; do
        if [[ ! -f "${tools_dir}/${b}" ]]; then
            log_error "Missing required tool binary: ${tools_dir}/${b}"
            return 1
        fi
    done
    log_info "All Cargo tools verified and cached in ${tools_dir}."
}

resolve_rust_channel_url() {
    local target_triple="$1"
    local channel_url="https://static.rust-lang.org/dist/channel-rust-stable.toml"
    
    python3 -c "
import urllib.request, re, os, ssl
ctx = ssl.create_default_context(cafile=os.environ.get('SSL_CERT_FILE'))
with urllib.request.urlopen('${channel_url}', context=ctx) as f:
    content = f.read().decode('utf-8')
m = re.search(r'\[pkg\.rust\.target\.' + re.escape('${target_triple}') + r'\][\s\S]*?url\s*=\s*\"([^\"]+)\"', content)
if m:
    print(m.group(1))
else:
    raise SystemExit(1)
"
}

install_rust_tarball() {
    local tarball="$1"
    local dest_dir="$2"
    local target_triple="$3"

    if [[ -d "${dest_dir}" ]] && [[ -f "${dest_dir}/bin/rustc.exe" ]] && [[ -f "${dest_dir}/bin/cargo.exe" ]] && [[ -f "${dest_dir}/bin/clippy-driver.exe" ]] && [[ -f "${dest_dir}/bin/rustfmt.exe" ]]; then
        log_info "Rust toolchain already unpacked at ${dest_dir}."
        return 0
    fi

    log_info "Unpacking Rust toolchain (${target_triple}) to ${dest_dir}..."
    local tmp_extract="${BUILD_DIR}/rust_unpack_${target_triple}_$$"
    rm -rf "${tmp_extract}" "${dest_dir}"
    mkdir -p "${tmp_extract}"

    tar -xzf "${tarball}" -C "${tmp_extract}" --strip-components=1
    if [[ -f "${tmp_extract}/install.sh" ]]; then
        log_info "Executing rust-installer install.sh with clippy and rustfmt..."
        bash "${tmp_extract}/install.sh" \
            --prefix="${dest_dir}" \
            --components="rustc,cargo,rust-std-${target_triple},clippy-preview,rustfmt-preview" \
            --disable-ldconfig
    else
        log_warn "install.sh not found, manually merging components..."
        mkdir -p "${dest_dir}/bin" "${dest_dir}/lib"
        for comp in rustc cargo "rust-std-${target_triple}" clippy-preview rustfmt-preview; do
            if [[ -d "${tmp_extract}/${comp}" ]]; then
                cp -r "${tmp_extract}/${comp}"/* "${dest_dir}/"
            fi
        done
    fi

    rm -rf "${tmp_extract}"

    # Verify installation
    if [[ ! -f "${dest_dir}/bin/rustc.exe" ]] || [[ ! -f "${dest_dir}/bin/clippy-driver.exe" ]] || [[ ! -f "${dest_dir}/bin/rustfmt.exe" ]]; then
        log_error "Required Rust toolchain binaries not found in ${dest_dir}/bin!"
        return 1
    fi

    # Also generate a compressed archive for rapid in-VM deployment
    local tar_archive="${dest_dir}.tar.gz"
    rm -f "${tar_archive}"
    log_info "Creating single-file archive ${tar_archive} for rapid VM extraction..."
    tar -czf "${tar_archive}" -C "${dest_dir}" .

    log_info "Rust toolchain (${target_triple}) installed and archived successfully."
}
