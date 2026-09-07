# Windows Server 2025 Standard Core 根母盘镜像 (Base Image)

## 1. 镜像概述
本目录包含构建 **Windows Server 2025 Standard Core** 根母盘 (`output/win2025-core.qcow2`) 所需的全部物料与构建脚本。
根母盘作为整套树状镜像架构的基座，保证最小化、无多余开发工具污染，并集成 VirtIO 驱动、Guest Agent、OpenSSH Server 及通用的下游配置引导器 (`provision-runner.ps1`)。

## 2. 文件清单
- `Autounattend.xml`: WinPE 安装阶段无人值守应答文件（绕过硬件检查、自动分区、跳过 OOBE）。
- `provision.ps1`: 母盘系统就绪后首次登录执行的配置脚本（安装 VirtIO Guest Tools、配置 OpenSSH、注册 ImageProvisionRunner 计划任务）。
- `provision-runner.ps1`: 通用下游配置引导器，在母盘开机自检时检测外部挂载的载荷光盘并自动执行下游初始化。
- `build.sh`: 独立构建母盘的自动化流水线脚本。

## 3. 规格参数
- **目标操作系统**：Windows Server 2025 Standard Core (Build 26100.1, 64-bit)
- **输出格式**：QCOW2 (zlib 压缩)
- **虚拟磁盘容量**：64 GB (动态精简置备，压缩后约 4.2 GB)
- **管理员凭据**：
  - 用户名：`Administrator`
  - 密码：`Admin1234!`
  - 自动登录：已启用
- **内置服务**：
  - OpenSSH Server (端口 22)
  - VirtIO Guest Tools (NetKVM 网卡、viostor 磁盘、Balloon 内存气球、QEMU Guest Agent)
  - ImageProvisionRunner (系统级调度任务)

## 4. 构建方法
在项目根目录或本目录下直接执行：
```bash
# 方式 1: 直接运行构建脚本
bash images/base/build.sh

# 方式 2: 使用 Devbox 命令
devbox run build:base

# 方式 3: 使用根编排脚本
bash scripts/build.sh base
```
构建成功后产物将生成在 `output/win2025-core.qcow2` 及元数据文件 `output/win2025-core.json`。
