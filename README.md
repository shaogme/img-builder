# Windows Server 2025 Core (Rust GNU) 基础镜像构建工程

## 1. 项目简介
本工程用于在 NixOS (含 QEMU / KVM) 宿主环境下，基于官方 Windows Server 2025 Standard Core 镜像与 VirtIO 驱动集合包，全自动构建轻量化、高性能的 QCOW2 虚拟机基础镜像。

镜像默认内置完整的 Rust GNU (`x86_64-pc-windows-gnu`) 编译工具链，不依赖任何 Microsoft Visual C++ (MSVC) 组件。

## 2. 核心特性
- 操作系统：Windows Server 2025 ServerStandardCore (Build 26100.1，纯 Core 模式，无 GUI 桌面)。
- 纯净 GNU 工具链：集成 w64devkit 便携版 MinGW-w64 (GCC、Binutils、Make) 及 Rustup 官方稳定的 `x86_64-pc-windows-gnu` 工具链，彻底摆脱 MSVC 依赖。
- 零交互全自动安装：通过定制的 `Autounattend.xml` 自动处理 TPM/SecureBoot 限制绕过、VirtIO 驱动注入、磁盘自动分区格式化、产品密钥跳过与管理员账户首次自动登录。
- 自闭环自动化流水线：基于原生 Bash、QEMU 与 Devbox 管理的辅助工具，不依赖第三方复杂抽象层（如 Packer）。
- 虚拟化优化：集成 VirtIO Guest Tools (含 QEMU Guest Agent、Balloon 内存气泡、串口与网卡驱动)，并在镜像交付前执行系统垃圾清理与磁盘 Trim/零填充，产出高压缩比的 QCOW2 镜像。

## 3. 依赖规范与输入物料
### 3.1 宿主机依赖
- NixOS 系统级安装的 QEMU (支持 `qemu-system-x86_64` 及 `qemu-img`，需启用 `/dev/kvm` 硬件加速)。
- 辅助依赖通过 `devbox.json` 统一管理：
  - `cdrkit` (提供 `genisoimage`/`mkisofs` 生成辅助引导光盘)
  - `wimlib` (提供 `wiminfo` 等 WIM/ESD 镜像检查工具)
  - `dos2unix` (用于 Windows 脚本换行符转换)

### 3.2 输入物料
- `ISO/26100.1_SERVERSTANDARD_X64_EN-US.ISO` (Windows Server 2025 Standard 镜像，仅含 Core 卷)
- `ISO/virtio-win-0.1.302.iso` (VirtIO Windows 驱动集合)

## 4. 目录结构说明
- `ISO/`：原始 ISO 介质目录。
- `templates/`：配置模板目录。
  - `Autounattend.xml`：Windows Server 2025 Core 无人值守安装应答文件。
  - `provision.ps1`：虚拟机内部环境部署脚本（VirtIO、MinGW、Rust、Cargo 配置、自检与清理）。
- `scripts/`：宿主机构建与监控脚本。
  - `build-windows-qcow2.sh`：主自动化构建流水线入口。
  - `monitor-boot.py`：处理光盘启动按键的 QEMU Monitor 辅助脚本。
- `output/`：构建生成目录（包含最终交付的 QCOW2 镜像、元数据配置 `win2025-core-rust-gnu.json` 及 `build.log` 日志）。

## 5. 构建与执行
进入项目根目录后，执行以下命令触发构建：
```bash
devbox run build
```
或者直接运行构建脚本：
```bash
bash scripts/build-windows-qcow2.sh
```

构建流水线包含三个阶段：
1. 阶段一（Windows Setup）：挂载 Windows ISO、VirtIO 驱动盘及生成的 OEMDRV 辅助光盘，自动完成存储驱动加载、分区格式化及系统镜像写入，完成后虚拟机自动平滑重启。
2. 阶段二（Provisioning）：从虚拟机磁盘启动，以 Administrator 账户自动登录并执行 `provision.ps1`，完成驱动工具箱安装、MinGW 与 Rust GNU 部署、环境变量注入、编译自测及系统关机。
3. 阶段三（压缩与收敛）：调用 `qemu-img convert -c` 对磁盘执行深度簇压缩，输出最终的 QCOW2 基础镜像。

## 6. 产物规格与使用说明
### 6.1 镜像参数
- 镜像文件：`output/win2025-core-rust-gnu.qcow2`
- 元数据文件：`output/win2025-core-rust-gnu.json`（记录账号密码、端口及软件清单）
- 虚拟大小：64 GiB（精简置备，按需扩展）
- 压缩后实际体积：约 5.5 GiB
- 格式：QCOW2 (压缩方式: zlib)
- 登录凭据：用户名 `Administrator`，密码 `Admin1234!`

### 6.2 凭据与规格配置文件 (JSON)
在生成 QCOW2 镜像的同时，构建脚本会在同级目录下自动导出 `win2025-core-rust-gnu.json`，方便 CI/CD 流水线或自动化测试直接读取：
```json
{
  "credentials": {
    "username": "Administrator",
    "password": "Admin1234!",
    "auto_logon": true
  },
  "network_and_remote": {
    "ssh": {
      "enabled": true,
      "port": 22
    }
  }
}
```

### 6.3 虚拟机启动示例
使用 QEMU 启动该镜像的参考命令：
```bash
qemu-system-x86_64 \
    -enable-kvm \
    -m 4096 \
    -smp 4 \
    -cpu host \
    -drive file=output/win2025-core-rust-gnu.qcow2,if=virtio,format=qcow2 \
    -netdev user,id=net0,hostfwd=tcp::2222-:22 \
    -device virtio-net-pci,netdev=net0 \
    -vnc 127.0.0.1:1
```
- SSH 远程管理：`ssh Administrator@127.0.0.1 -p 2222`
- VNC 画面查看：`vncviewer 127.0.0.1:5901`

## 7. 关键问题排查与设计要点
1. 驱动去重避免 0x80070103 错误：
   Windows Server 2025 (26100 内核) 在 WinPE 阶段对驱动注入执行严格去重。如果应答文件中声明了多个指向同一驱动文件的不同路径，会导致安装程序报 `0x80070103` 错误中断。因此 `Autounattend.xml` 中仅配置单条明确的存储驱动路径 (`E:\viostor\2k25\amd64`)。
2. 产品密钥跳过：
   Server Core 镜像在无人值守配置中需要显式设置 `ProductKey` 的 `WillShowUI` 为 `Never`，配合 OEM 声明通道，避免安装中断在密钥输入界面。
3. Rust GNU 工具链独立性：
   Rust GNU ABI 编译链接依赖 GCC、Binutils 以及配套 C 运行时头文件。方案内置便携式的 w64devkit，并将 `gcc.exe` 与 `ar.exe` 配置为默认链接器，彻底解耦 MSVC。
