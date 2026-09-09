# Rust GNU 工具链衍生镜像 (win2025-core-rust-gnu.qcow2)

## 1. 镜像概述
本目录包含基于根母盘 (`win2025-core.qcow2`) 派生构建 **Rust GNU (MinGW-w64)** 开发环境虚拟机镜像所需的文件与脚本。
通过 QCOW2 Copy-on-Write 差分机制，构建过程不修改母盘。构建完成经自测验证后，自动合并压缩产出完整的交付镜像 `output/win2025-core-rust-gnu.qcow2`。

## 2. 文件清单
- `provision.ps1`: 工具链配置与测试脚本。负责在线拉取并部署最新版 w64devkit MinGW-w64、Visual C++ Redistributable (vc_redist)、Rustup 与 `x86_64-pc-windows-gnu` 稳定版工具链，配置系统环境变量与 Cargo 编译器参数，在线部署最新版 `cargo-binstall` 并通过其安装 10 大常用工具，并执行示例 Rust 程序与全工具链自检。
- `build.sh`: 独立构建本衍生镜像的自动化脚本。全链路在线动态获取各组件最新版本，不锁定特定程序版本。

## 3. 工具链规格
- **C/C++ 工具链**：w64devkit (GCC, G++, Binutils, Make, GDB)
- **C/C++ 运行库**：Microsoft Visual C++ 2015-2022 Redistributable (`vc_redist.x64.exe`, `vcruntime140.dll`)
- **Rust 目标架构**：`x86_64-pc-windows-gnu` (Stable)
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
- **构建链接配置**：Cargo 配置自动绑定 `linker = "gcc"` 与 `ar = "ar"`。
- **自测验证**：置备阶段自动创建 `rust_verify_project` 执行 `cargo build`、测试生成程序运行，并全面检验 `cargo-binstall` 及各工具 CLI 版本响应。

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
