# Rust MSVC 工具链衍生镜像 (win2025-core-rust-msvc.qcow2)

## 1. 镜像概述
本目录包含基于根母盘 (`win2025-core.qcow2`) 派生构建 **Rust MSVC (Visual Studio 2022 Build Tools)** 开发环境虚拟机镜像所需的文件与脚本。
满足针对 Windows 原生 ABI、Windows SDK 依赖库以及与 MSVC 编译链接生态对接的需求。同样利用 QCOW2 差分层构建，避免污染母盘。

## 2. 文件清单
- `provision.ps1`: 工具链配置与测试脚本。负责自动化安装 Visual Studio 2022 Build Tools (VCTools, MSVC x86/x64, Windows 10/11 SDK 20348)、安装 Rustup 与 `x86_64-pc-windows-msvc` 稳定版工具链、配置系统环境变量及 VsDevCmd，并执行 Rust 原生编译自验。
- `build.sh`: 独立构建本衍生镜像的自动化脚本。
- `packages/` (可选): 本地离线安装包存放目录（若根目录 `packages/` 已有离线包则优先自动加载）。

## 3. 工具链规格
- **C/C++ 工具链**：Microsoft Visual Studio 2022 Build Tools (`cl.exe`, `link.exe`, `lib.exe`, `vswhere.exe`)
- **Windows SDK**：Windows 10/11 SDK (20348)
- **Rust 目标架构**：`x86_64-pc-windows-msvc` (Stable)
- **MSVC 依赖**：全功能原生 MSVC 工具链与 Windows 头文件/库。
- **自测验证**：置备阶段自动检测 VS 环境，创建 `rust_verify_msvc` 执行 `cargo build` 并运行生成程序验证通过。

## 4. 构建方法
```bash
# 方式 1: 直接运行构建脚本 (若根母盘未就绪将自动触发母盘构建)
bash images/rust/msvc/build.sh

# 方式 2: 使用 Devbox 命令
devbox run build:msvc

# 方式 3: 快速差分开发模式 (仅保留极轻量的 CoW 增量层)
bash images/rust/msvc/build.sh --overlay-only
```
产物生成在 `output/win2025-core-rust-msvc.qcow2` 及元数据文件 `output/win2025-core-rust-msvc.json`。
