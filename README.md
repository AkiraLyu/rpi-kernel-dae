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
sudo pacman -Syu base-devel git bc bison flex ncurses openssl \
  aarch64-linux-gnu-gcc pahole dpkg
```

其中 `pahole` 用于在启用 `CONFIG_DEBUG_INFO_BTF=y` 时生成 BTF 信息。

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
KERNEL_BRANCH=rpi-6.6.y ./scripts/build-rpi-dae-kernel.sh

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
sudo apt install /tmp/rpi-dae-kernel_*_arm64.deb
```

安装脚本会按顺序寻找启动分区目录：

1. `/boot/firmware`
2. `/boot`

安装时会复制内核镜像、dtb 和 overlays，并创建备份目录，例如：

```text
/boot/firmware/rpi-dae-kernel-backup-YYYYmmdd-HHMMSS
```

## 卸载和回退

卸载包：

```sh
sudo apt remove rpi-dae-kernel
```

卸载时会删除该包安装到 `/boot/firmware` 或 `/boot` 下的内核镜像，但不会改写`config.txt`。如果要切回原来的内核，需要手动修改 `kernel=` 行，或者从安装时创建的备份目录恢复 `config.txt`。
