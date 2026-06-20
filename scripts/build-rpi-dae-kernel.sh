#!/usr/bin/env bash
set -euo pipefail

# Raspberry Pi 5 / 64-bit / dae kernel build script
#
# 默认目标：
#   Raspberry Pi 5
#   ARCH=arm64
#   CROSS_COMPILE=aarch64-linux-gnu-
#   DEFCONFIG=bcm2712_defconfig
#   KERNEL_IMAGE_NAME=kernel_2712
#
# 可覆盖变量示例：
#   LOCALVERSION=-dae \
#   KERNEL_BRANCH=rpi-6.6.y \
#   ./scripts/build-rpi-dae-kernel.sh

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

LINUX_DIR="${LINUX_DIR:-$REPO_ROOT/linux}"
DIST_DIR="${DIST_DIR:-$REPO_ROOT/dist}"
CONFIG_DIR="${CONFIG_DIR:-$REPO_ROOT/configs}"
CONFIG_FRAGMENT="${CONFIG_FRAGMENT:-$CONFIG_DIR/dae-btf.fragment}"

KERNEL_REPO="${KERNEL_REPO:-https://github.com/raspberrypi/linux}"
KERNEL_BRANCH="${KERNEL_BRANCH:-}"

ARCH="${ARCH:-arm64}"
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
DEFCONFIG="${DEFCONFIG:-bcm2712_defconfig}"
KERNEL_IMAGE_NAME="${KERNEL_IMAGE_NAME:-kernel_2712}"
LOCALVERSION="${LOCALVERSION:--dae}"
JOBS="${JOBS:-$(nproc)}"

export ARCH
export CROSS_COMPILE

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: missing command: $1" >&2
    exit 1
  }
}

need_cmd git
need_cmd make
need_cmd bc
need_cmd bison
need_cmd flex
need_cmd pahole
need_cmd bindgen
need_cmd "${CROSS_COMPILE}gcc"

mkdir -p "$DIST_DIR" "$CONFIG_DIR"

if [[ ! -d "$LINUX_DIR/.git" ]]; then
  echo "==> Cloning Raspberry Pi kernel source..."
  if [[ -n "$KERNEL_BRANCH" ]]; then
    git clone --depth=1 --branch "$KERNEL_BRANCH" "$KERNEL_REPO" "$LINUX_DIR"
  else
    git clone --depth=1 "$KERNEL_REPO" "$LINUX_DIR"
  fi
else
  echo "==> Using existing kernel source: $LINUX_DIR"
fi

cat > "$CONFIG_FRAGMENT" <<EOF
CONFIG_LOCALVERSION="$LOCALVERSION"
# CONFIG_LOCALVERSION_AUTO is not set

CONFIG_IKCONFIG=y
CONFIG_IKCONFIG_PROC=y

CONFIG_RUST=y

CONFIG_BPF=y
CONFIG_BPF_SYSCALL=y
CONFIG_BPF_JIT=y
CONFIG_CGROUPS=y

CONFIG_KPROBES=y
CONFIG_KPROBE_EVENTS=y
CONFIG_BPF_EVENTS=y

CONFIG_NET_INGRESS=y
CONFIG_NET_EGRESS=y
CONFIG_NET_SCH_INGRESS=m
CONFIG_NET_CLS_BPF=y
CONFIG_NET_CLS_ACT=y

CONFIG_BPF_STREAM_PARSER=y

CONFIG_DEBUG_INFO=y
# CONFIG_DEBUG_INFO_REDUCED is not set
# CONFIG_DEBUG_INFO_NONE is not set
CONFIG_DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT=y
CONFIG_DEBUG_INFO_BTF=y
EOF

cd "$LINUX_DIR"

echo "==> Kernel source: $LINUX_DIR"
echo "==> ARCH=$ARCH"
echo "==> CROSS_COMPILE=$CROSS_COMPILE"
echo "==> DEFCONFIG=$DEFCONFIG"
echo "==> KERNEL_IMAGE_NAME=$KERNEL_IMAGE_NAME"
echo "==> LOCALVERSION=$LOCALVERSION"

echo "==> Generating base config..."
make "$DEFCONFIG"

echo "==> Checking Rust toolchain..."
make rustavailable

echo "==> Merging dae/BTF/Rust config fragment..."
./scripts/kconfig/merge_config.sh -m .config "$CONFIG_FRAGMENT"

# 再用 scripts/config 强制一遍关键项，避免 fragment 被 choice 覆盖时不明显。
scripts/config --set-str LOCALVERSION "$LOCALVERSION"
scripts/config --disable LOCALVERSION_AUTO

scripts/config --enable IKCONFIG
scripts/config --enable IKCONFIG_PROC

scripts/config --enable RUST
if grep -q '^config GENDWARFKSYMS$' kernel/module/Kconfig; then
  scripts/config --disable GENKSYMS
  scripts/config --enable GENDWARFKSYMS
else
  scripts/config --disable MODVERSIONS
fi

scripts/config --enable BPF
scripts/config --enable BPF_SYSCALL
scripts/config --enable BPF_JIT
scripts/config --enable CGROUPS

scripts/config --enable KPROBES
scripts/config --enable KPROBE_EVENTS
scripts/config --enable BPF_EVENTS

scripts/config --enable NET_INGRESS
scripts/config --enable NET_EGRESS
scripts/config --module NET_SCH_INGRESS
scripts/config --enable NET_CLS_BPF
scripts/config --enable NET_CLS_ACT

scripts/config --enable BPF_STREAM_PARSER

scripts/config --enable DEBUG_INFO
scripts/config --disable DEBUG_INFO_REDUCED
scripts/config --disable DEBUG_INFO_NONE || true
scripts/config --enable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT || true
scripts/config --enable DEBUG_INFO_BTF

echo "==> Resolving config dependencies..."
make olddefconfig

echo "==> Checking pahole..."
pahole --version

echo "==> Verifying required config symbols..."
required_y=(
  CONFIG_BPF
  CONFIG_BPF_SYSCALL
  CONFIG_BPF_JIT
  CONFIG_CGROUPS
  CONFIG_KPROBES
  CONFIG_KPROBE_EVENTS
  CONFIG_BPF_EVENTS
  CONFIG_NET_INGRESS
  CONFIG_NET_EGRESS
  CONFIG_NET_CLS_BPF
  CONFIG_NET_CLS_ACT
  CONFIG_BPF_STREAM_PARSER
  CONFIG_DEBUG_INFO
  CONFIG_DEBUG_INFO_BTF
  CONFIG_IKCONFIG
  CONFIG_IKCONFIG_PROC
  CONFIG_RUST
)

failed=0

for sym in "${required_y[@]}"; do
  if ! grep -q "^${sym}=y$" .config; then
    echo "error: ${sym} is not y" >&2
    failed=1
  fi
done

if ! grep -q '^CONFIG_NET_SCH_INGRESS=m$\|^CONFIG_NET_SCH_INGRESS=y$' .config; then
  echo "error: CONFIG_NET_SCH_INGRESS is neither m nor y" >&2
  failed=1
fi

if grep -q '^CONFIG_MODVERSIONS=y$' .config && ! grep -q '^CONFIG_GENDWARFKSYMS=y$' .config; then
  echo "error: CONFIG_MODVERSIONS requires CONFIG_GENDWARFKSYMS for Rust" >&2
  failed=1
fi

if ! grep -q '^# CONFIG_DEBUG_INFO_REDUCED is not set$' .config; then
  echo "error: CONFIG_DEBUG_INFO_REDUCED is not disabled" >&2
  failed=1
fi

if [[ "$failed" -ne 0 ]]; then
  echo
  echo "Some required options were not enabled."
  echo "Try running:"
  echo "  cd $LINUX_DIR"
  echo "  make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE rustavailable"
  echo "  make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE menuconfig"
  echo
  exit 1
fi

echo "==> Building kernel, modules and dtbs..."
make -j"$JOBS" Image modules dtbs

KERNEL_RELEASE="$(make -s kernelrelease)"

cat > "$DIST_DIR/build.env" <<EOF
ARCH=$ARCH
CROSS_COMPILE=$CROSS_COMPILE
DEFCONFIG=$DEFCONFIG
KERNEL_IMAGE_NAME=$KERNEL_IMAGE_NAME
LOCALVERSION=$LOCALVERSION
KERNEL_RELEASE=$KERNEL_RELEASE
LINUX_DIR=$LINUX_DIR
EOF

cp .config "$DIST_DIR/config-$KERNEL_RELEASE"

echo
echo "==> Build complete."
echo "Kernel release: $KERNEL_RELEASE"
echo "Config saved to: $DIST_DIR/config-$KERNEL_RELEASE"
echo "Build metadata:  $DIST_DIR/build.env"
