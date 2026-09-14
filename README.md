# rpi-kernel-packaging

这个仓库用于构建并打包适合 dae 使用的 Raspberry Pi 内核。背景和手工流程见：[树莓派编译内核运行 dae](https://www.akira-uestc.site/zh-cn/posts/%E6%A0%91%E8%8E%93%E6%B4%BE%E7%BC%96%E8%AF%91%E5%86%85%E6%A0%B8%E8%BF%90%E8%A1%8Cdae/)
默认目标是 Raspberry Pi 5 / BCM2712 / 64 位内核：

- `ARCH=arm64`
- `CROSS_COMPILE=aarch64-linux-gnu-`
- `DEFCONFIG=bcm2712_defconfig`
- `KERNEL_IMAGE_NAME=kernel_2712`

如果目标不是 Raspberry Pi 5，需要按实际型号覆盖`DEFCONFIG`和`KERNEL_IMAGE_NAME`。

## 准备环境

以 Arch Linux 构建机为例：

```sh
run0 pacman -Syu base-devel git bc bison flex ncurses openssl libelf \
  aarch64-linux-gnu-gcc pahole dpkg
```

其中 `pahole` 用于在启用 `CONFIG_DEBUG_INFO_BTF=y` 时生成 BTF 信息。

Debian 13 / Trixie 构建机可安装：

```sh
run0 apt install build-essential git bc bison flex libncurses-dev libssl-dev \
  libelf-dev pahole crossbuild-essential-arm64 dpkg xz-utils zstd
```

默认 `ENABLE_RUST=0`，不要求 Rust 工具链。dae 需要 eBPF/BTF，但不要求内核启用 Rust。
如果需要支持 Rust 内核模块，先补充工具链，再使用 `ENABLE_RUST=1`：

```sh
# Arch Linux
run0 pacman -Syu rust rust-src rust-bindgen clang llvm elfutils

# Debian 13 / Trixie
run0 apt install rustc rust-src bindgen clang llvm libclang-dev libdw-dev

ENABLE_RUST=1 ./scripts/build-rpi-dae-kernel.sh
```

`rust-src` 必须与 `rustc` 匹配；使用 rustup 管理工具链时，用
`rustup component add rust-src` 安装对应源码。启用 Rust 后，脚本会执行
`make rustavailable` 检查所选内核对 Rust、bindgen、libclang 和标准库源码的要求。
保留模块版本校验时还会启用 `GENDWARFKSYMS`，需要 libdw/libelf 开发文件。
版本与工具链要求参见[内核 Rust 文档](https://github.com/raspberrypi/linux/blob/rpi-6.18.y/Documentation/rust/quick-start.rst)。

## 编译内核

直接运行：

```sh
./scripts/build-rpi-dae-kernel.sh
```

构建产物和元数据：

- `linux/`：Raspberry Pi 内核源码和构建目录
- `configs/dae-btf.fragment`：脚本生成的配置片段
- `dist/config-<kernel-release>`：最终内核配置
- `dist/build.env`：本次构建的关键变量

常用覆盖参数：

```sh
KERNEL_BRANCH=rpi-6.18.y ./scripts/build-rpi-dae-kernel.sh

JOBS=8 ./scripts/build-rpi-dae-kernel.sh

DEFCONFIG=bcm2711_defconfig \
KERNEL_IMAGE_NAME=kernel8 \
./scripts/build-rpi-dae-kernel.sh
```

## 打包 deb

内核编译成功后，运行：

```sh
./scripts/package-rpi-dae-kernel-deb.sh
```

打包脚本会从 `linux/` 构建目录收集：

- 内核镜像
- 内核模块
- dtb 设备树文件
- overlays
- 最终内核配置

生成的文件位于 `dist/`：

```text
rpi-dae-kernel_<kernel-release>-1_arm64.deb
SHA256SUMS
```

可覆盖包名和维护者信息：

```sh
PKG_NAME=rpi-dae-kernel \
MAINTAINER='Your Name <you@example.com>' \
./scripts/package-rpi-dae-kernel-deb.sh
```

## 在树莓派上安装

把 deb 包复制到树莓派，然后安装：

```sh
run0 apt install /tmp/rpi-dae-kernel_*_arm64.deb
```

安装脚本会按顺序寻找启动分区目录：

1. `/boot/firmware`
2. `/boot`

安装时会复制内核镜像、dtb 和 overlays，并创建备份目录，例如：

```text
/boot/firmware/rpi-dae-kernel-backup-YYYYmmdd-HHMMSS
```

内核和对应 initramfs 安装完成后，脚本会在 `config.txt` 末尾维护
`# BEGIN rpi-dae-kernel` 到 `# END rpi-dae-kernel` 的配置块。块内使用 `[all]`
选择本次安装的内核，并显式指定对应 initramfs；新装系统没有 `kernel=` 行也会生效。
原有机型分段、`include` 和用户配置会保留，重复安装只更新这个配置块。
如果使用自定义 `PKG_NAME`，配置块标记会使用对应包名。

安装后重启，并确认 `uname -r` 与构建产物的内核版本一致，且
`/sys/kernel/btf/vmlinux` 存在。

## 卸载和回退

先从 `config.txt` 中删除上述完整配置块，确认原有启动配置选择的是仍存在的内核；
也可以从安装前的备份恢复。重启并用 `uname -r` 确认已切回原内核，再卸载包：

```sh
run0 apt remove rpi-dae-kernel
```

卸载时会删除该包安装到 `/boot/firmware` 或 `/boot` 下的内核镜像和 initramfs，
但不会自动改写 `config.txt` 或恢复 dtb/overlays；需要恢复这些文件时使用安装前的备份。
