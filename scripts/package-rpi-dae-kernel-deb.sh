#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

LINUX_DIR="${LINUX_DIR:-$REPO_ROOT/linux}"
DIST_DIR="${DIST_DIR:-$REPO_ROOT/dist}"

ARCH="${ARCH:-arm64}"
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
DEB_ARCH="${DEB_ARCH:-arm64}"

PKG_NAME="${PKG_NAME:-rpi-dae-kernel}"
KERNEL_IMAGE_NAME="${KERNEL_IMAGE_NAME:-kernel_2712}"
MAINTAINER="${MAINTAINER:-Akira <akira@example.com>}"

export ARCH
export CROSS_COMPILE

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: missing command: $1" >&2
    exit 1
  }
}

need_cmd make
need_cmd dpkg-deb
need_cmd sha256sum

if [[ ! -d "$LINUX_DIR" ]]; then
  echo "error: kernel source directory not found: $LINUX_DIR" >&2
  exit 1
fi

cd "$LINUX_DIR"

KERNEL_RELEASE="$(make -s kernelrelease)"
PKG_VERSION="${KERNEL_RELEASE}-1"
BOOT_IMAGE="${KERNEL_IMAGE_NAME}-dae-${KERNEL_RELEASE}.img"

WORK_DIR="$(mktemp -d)"
PKG_ROOT="$WORK_DIR/${PKG_NAME}_${PKG_VERSION}_${DEB_ARCH}"

mkdir -p "$DIST_DIR"
mkdir -p "$PKG_ROOT/DEBIAN"
mkdir -p "$PKG_ROOT/usr/lib/$PKG_NAME/$KERNEL_RELEASE"
mkdir -p "$PKG_ROOT/usr/share/doc/$PKG_NAME"

echo "==> Packaging kernel release: $KERNEL_RELEASE"
echo "==> Package version: $PKG_VERSION"
echo "==> Boot image name: $BOOT_IMAGE"
echo "==> Package root: $PKG_ROOT"

echo "==> Installing modules into package root..."
make \
  ARCH="$ARCH" \
  CROSS_COMPILE="$CROSS_COMPILE" \
  INSTALL_MOD_PATH="$PKG_ROOT" \
  DEPMOD=/bin/true \
  modules_install

# 避免把构建机上的源码路径做成 /lib/modules/<rel>/build 的绝对软链接塞进包里。
rm -f "$PKG_ROOT/lib/modules/$KERNEL_RELEASE/build"
rm -f "$PKG_ROOT/lib/modules/$KERNEL_RELEASE/source"

echo "==> Copying kernel image, dtbs and overlays..."

case "$ARCH" in
  arm64)
    IMAGE_PATH="arch/arm64/boot/Image"
    DTB_GLOB="arch/arm64/boot/dts/broadcom/*.dtb"
    OVERLAY_DIR="arch/arm64/boot/dts/overlays"
    ;;
  arm)
    IMAGE_PATH="arch/arm/boot/zImage"
    if compgen -G "arch/arm/boot/dts/broadcom/*.dtb" >/dev/null; then
      DTB_GLOB="arch/arm/boot/dts/broadcom/*.dtb"
    else
      DTB_GLOB="arch/arm/boot/dts/*.dtb"
    fi
    OVERLAY_DIR="arch/arm/boot/dts/overlays"
    ;;
  *)
    echo "error: unsupported ARCH=$ARCH" >&2
    exit 1
    ;;
esac

if [[ ! -f "$IMAGE_PATH" ]]; then
  echo "error: kernel image not found: $IMAGE_PATH" >&2
  echo "Run build script first." >&2
  exit 1
fi

cp "$IMAGE_PATH" "$PKG_ROOT/usr/lib/$PKG_NAME/$KERNEL_RELEASE/$BOOT_IMAGE"

mkdir -p "$PKG_ROOT/usr/lib/$PKG_NAME/$KERNEL_RELEASE/dtbs"
# shellcheck disable=SC2086
cp $DTB_GLOB "$PKG_ROOT/usr/lib/$PKG_NAME/$KERNEL_RELEASE/dtbs/"

mkdir -p "$PKG_ROOT/usr/lib/$PKG_NAME/$KERNEL_RELEASE/overlays"
cp "$OVERLAY_DIR"/*.dtb* "$PKG_ROOT/usr/lib/$PKG_NAME/$KERNEL_RELEASE/overlays/" 2>/dev/null || true
cp "$OVERLAY_DIR"/README "$PKG_ROOT/usr/lib/$PKG_NAME/$KERNEL_RELEASE/overlays/" 2>/dev/null || true

cp .config "$PKG_ROOT/usr/share/doc/$PKG_NAME/config-$KERNEL_RELEASE"

cat > "$PKG_ROOT/usr/share/doc/$PKG_NAME/README.Debian" <<EOF
Custom Raspberry Pi kernel for dae.

Kernel release:
  $KERNEL_RELEASE

Boot image:
  $BOOT_IMAGE

After installation, reboot and verify:

  uname -r

Check dae-related kernel options:

  zcat /proc/config.gz | grep -E 'CONFIG_(DEBUG_INFO|DEBUG_INFO_BTF|KPROBES|KPROBE_EVENTS|BPF|BPF_SYSCALL|BPF_JIT|BPF_STREAM_PARSER|NET_CLS_ACT|NET_SCH_INGRESS|NET_INGRESS|NET_EGRESS|NET_CLS_BPF|BPF_EVENTS|CGROUPS)=|# CONFIG_DEBUG_INFO_REDUCED is not set'
EOF

gzip -n -9 "$PKG_ROOT/usr/share/doc/$PKG_NAME/README.Debian"

INSTALLED_SIZE="$(du -sk "$PKG_ROOT" | cut -f1)"

cat > "$PKG_ROOT/DEBIAN/control" <<EOF
Package: $PKG_NAME
Version: $PKG_VERSION
Section: kernel
Priority: optional
Architecture: $DEB_ARCH
Maintainer: $MAINTAINER
Installed-Size: $INSTALLED_SIZE
Depends: kmod, initramfs-tools
Description: Custom Raspberry Pi kernel for dae
 Custom Raspberry Pi Linux kernel with dae-required eBPF and BTF options.
 Kernel release: $KERNEL_RELEASE
 Boot image: $BOOT_IMAGE
EOF

cat > "$PKG_ROOT/DEBIAN/postinst" <<EOF
#!/bin/sh
set -e

PKG_NAME="$PKG_NAME"
KERNEL_RELEASE="$KERNEL_RELEASE"
BOOT_IMAGE="$BOOT_IMAGE"
AUTO_INITRAMFS="\$(printf '%s\n' "\$BOOT_IMAGE" | sed 's/^kernel/initramfs/; s/[.]img$//')"

find_bootdir() {
  for d in /boot/firmware /boot; do
    if [ -f "\$d/config.txt" ] || [ -d "\$d/overlays" ]; then
      echo "\$d"
      return 0
    fi
  done
  return 1
}

BOOTDIR="\$(find_bootdir || true)"

if [ -z "\$BOOTDIR" ]; then
  echo "error: cannot find Raspberry Pi boot directory: /boot/firmware or /boot" >&2
  exit 1
fi

echo "Installing Raspberry Pi boot files into \$BOOTDIR"

mkdir -p "\$BOOTDIR/overlays"

BACKUP_DIR="\$BOOTDIR/${PKG_NAME}-backup-\$(date +%Y%m%d-%H%M%S)"
mkdir -p "\$BACKUP_DIR"

# 备份可能被覆盖的 dtb / overlay / config。
cp "\$BOOTDIR"/*.dtb "\$BACKUP_DIR/" 2>/dev/null || true
cp "\$BOOTDIR"/config.txt "\$BACKUP_DIR/config.txt" 2>/dev/null || true

if [ -d "\$BOOTDIR/overlays" ]; then
  mkdir -p "\$BACKUP_DIR/overlays"
  cp "\$BOOTDIR"/overlays/*.dtb* "\$BACKUP_DIR/overlays/" 2>/dev/null || true
  cp "\$BOOTDIR"/overlays/README "\$BACKUP_DIR/overlays/" 2>/dev/null || true
fi

cp -f "/usr/lib/\$PKG_NAME/\$KERNEL_RELEASE/\$BOOT_IMAGE" "\$BOOTDIR/\$BOOT_IMAGE"
cp -f /usr/lib/\$PKG_NAME/\$KERNEL_RELEASE/dtbs/*.dtb "\$BOOTDIR/" 2>/dev/null || true
cp -f /usr/lib/\$PKG_NAME/\$KERNEL_RELEASE/overlays/*.dtb* "\$BOOTDIR/overlays/" 2>/dev/null || true
cp -f "/usr/share/doc/\$PKG_NAME/config-\$KERNEL_RELEASE" "/boot/config-\$KERNEL_RELEASE"

if [ -f "/usr/lib/\$PKG_NAME/\$KERNEL_RELEASE/overlays/README" ]; then
  cp -f "/usr/lib/\$PKG_NAME/\$KERNEL_RELEASE/overlays/README" "\$BOOTDIR/overlays/README"
fi

if [ -f "\$BOOTDIR/config.txt" ]; then
  if grep -q '^kernel=' "\$BOOTDIR/config.txt"; then
    sed -i "0,/^kernel=/{s|^kernel=.*|kernel=\$BOOT_IMAGE|}" "\$BOOTDIR/config.txt"
  else
    echo "warning: \$BOOTDIR/config.txt does not contain a kernel= line; config.txt not modified" >&2
  fi
else
  echo "warning: \$BOOTDIR/config.txt not found; kernel image installed but config.txt not modified" >&2
fi

if [ -f "/boot/initrd.img-\$KERNEL_RELEASE" ]; then
  update-initramfs -u -k "\$KERNEL_RELEASE"
else
  update-initramfs -c -k "\$KERNEL_RELEASE"
fi
cp -f "/boot/initrd.img-\$KERNEL_RELEASE" "\$BOOTDIR/\$AUTO_INITRAMFS"

depmod "\$KERNEL_RELEASE" || true

echo "Installed \$PKG_NAME \$KERNEL_RELEASE"
echo "Boot image: \$BOOTDIR/\$BOOT_IMAGE"
echo "Initramfs: \$BOOTDIR/\$AUTO_INITRAMFS"
echo "Backup directory: \$BACKUP_DIR"
echo "Reboot, then verify with: uname -r"
EOF

chmod 0755 "$PKG_ROOT/DEBIAN/postinst"

cat > "$PKG_ROOT/DEBIAN/postrm" <<EOF
#!/bin/sh
set -e

PKG_NAME="$PKG_NAME"
KERNEL_RELEASE="$KERNEL_RELEASE"
BOOT_IMAGE="$BOOT_IMAGE"
AUTO_INITRAMFS="\$(printf '%s\n' "\$BOOT_IMAGE" | sed 's/^kernel/initramfs/; s/[.]img$//')"

if [ "\$1" = "remove" ] || [ "\$1" = "purge" ]; then
  rm -f "/boot/initrd.img-\$KERNEL_RELEASE" "/boot/config-\$KERNEL_RELEASE"
  for BOOTDIR in /boot/firmware /boot; do
    if [ -f "\$BOOTDIR/\$BOOT_IMAGE" ]; then
      rm -f "\$BOOTDIR/\$BOOT_IMAGE"
    fi
    if [ -f "\$BOOTDIR/\$AUTO_INITRAMFS" ]; then
      rm -f "\$BOOTDIR/\$AUTO_INITRAMFS"
    fi
  done
fi
EOF

chmod 0755 "$PKG_ROOT/DEBIAN/postrm"

DEB_PATH="$DIST_DIR/${PKG_NAME}_${PKG_VERSION}_${DEB_ARCH}.deb"

echo "==> Building deb package..."
dpkg-deb --build --root-owner-group "$PKG_ROOT" "$DEB_PATH"

cd "$DIST_DIR"
sha256sum "$(basename "$DEB_PATH")" > SHA256SUMS

echo
echo "==> Package complete."
ls -lh "$DEB_PATH" "$DIST_DIR/SHA256SUMS"
