# Rust MSVC 工具链衍生镜像 (win2025-core-rust-msvc.qcow2)

## 1. 镜像概述
本目录包含基于根母盘 (`win2025-core.qcow2`) 派生构建 **Rust MSVC (Visual Studio 2022 Build Tools)** 开发环境虚拟机镜像所需的文件与脚本。
满足针对 Windows 原生 ABI、Windows SDK 依赖库以及与 MSVC 编译链接生态对接的需求。同样利用 QCOW2 差分层构建，避免污染母盘。

## 2. 文件清单
- `provision.ps1`: 工具链配置与测试脚本。负责在线拉取最新 Visual Studio 2022 Build Tools (VCTools, MSVC x86/x64, 推荐 Windows SDK)、安装 Rustup 与 `x86_64-pc-windows-msvc` 稳定版工具链，配置系统环境变量及 VsDevCmd，在线部署最新版 `cargo-binstall` 并安装 10 大常用工具，并执行 Rust 原生编译与全工具链自验。
- `build.sh`: 独立构建本衍生镜像的自动化脚本。全链路在线动态获取各组件最新版本，不锁定特定程序版本。

## 3. 工具链规格
- **C/C++ 工具链**：Microsoft Visual Studio 2022 Build Tools (`cl.exe`, `link.exe`, `lib.exe`, `vswhere.exe`)
- **Windows SDK**：最新推荐 Windows SDK
- **Rust 目标架构**：`x86_64-pc-windows-msvc` (Stable)
- **Rust 包安装加速器**：`cargo-binstall`
- **预装 Rust 生态工具**（通过 `cargo-binstall` 安装）：
  - `sccache` (编译缓存加速)
  - `cargo-nextest` (新一代高性能测试运行器)
  - `cargo-sweep` (构建产物定时清理)
  - `cargo-geiger` (不安全代码 unsafe 检测)
  - `cargo-audit` (安全依赖漏洞审计)
  - `flamegraph` (性能火焰图生成器)
  - `samply` (采样性能剖析器)
  - `cargo-show-asm` (汇编与机器码查看器)
  - `cargo-expand` (宏展开调试工具)
  - `cargo-bloat` (二进制体积分析器)
- **MSVC 依赖**：全功能原生 MSVC 工具链与 Windows 头文件/库。
- **自测验证**：置备阶段自动检测 VS 环境，创建 `rust_verify_msvc` 执行 `cargo build` 并运行生成程序，并全面检验 `cargo-binstall` 及各工具 CLI 版本响应。

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
