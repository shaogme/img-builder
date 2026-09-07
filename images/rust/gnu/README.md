# Rust GNU 工具链衍生镜像 (win2025-core-rust-gnu.qcow2)

## 1. 镜像概述
本目录包含基于根母盘 (`win2025-core.qcow2`) 派生构建 **Rust GNU (MinGW-w64)** 开发环境虚拟机镜像所需的文件与脚本。
通过 QCOW2 Copy-on-Write 差分机制，构建过程不修改母盘。构建完成经自测验证后，自动合并压缩产出完整的交付镜像 `output/win2025-core-rust-gnu.qcow2`。

## 2. 文件清单
- `provision.ps1`: 工具链配置与测试脚本。负责部署 w64devkit MinGW-w64、安装 Rustup 与 `x86_64-pc-windows-gnu` 稳定版工具链、配置系统环境变量及 Cargo 编译器参数，并执行示例 Rust 程序编译自检。
- `build.sh`: 独立构建本衍生镜像的自动化脚本。
- `packages/` (可选): 本地离线安装包存放目录（若根目录 `packages/` 已有离线包则优先自动加载）。

## 3. 工具链规格
- **C/C++ 工具链**：w64devkit (GCC, G++, Binutils, Make, GDB)
- **Rust 目标架构**：`x86_64-pc-windows-gnu` (Stable)
- **MSVC 依赖**：完全无需 MSVC / Visual Studio，完全依赖原生开源 MinGW-w64 栈。
- **构建链接配置**：Cargo 配置自动绑定 `linker = "gcc"` 与 `ar = "ar"`。
- **自测验证**：置备阶段自动创建 `rust_verify_project` 执行 `cargo build` 并运行生成程序验证通过。

## 4. 构建方法
```bash
# 方式 1: 直接运行构建脚本 (若根母盘未就绪将自动触发母盘构建)
bash images/rust/gnu/build.sh

# 方式 2: 使用 Devbox 命令
devbox run build:gnu

# 方式 3: 快速差分开发模式 (仅保留极轻量的 CoW 增量层)
bash images/rust/gnu/build.sh --overlay-only
```
产物生成在 `output/win2025-core-rust-gnu.qcow2` 及元数据文件 `output/win2025-core-rust-gnu.json`。
