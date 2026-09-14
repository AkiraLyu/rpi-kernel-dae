#!/bin/sh
set -eu

# Keep package boot settings last so earlier model filters and includes cannot
# override them. Preserve the user's settings outside the managed block.
if [ "$#" -ne 4 ]; then
  echo "Usage: $0 CONFIG_FILE PACKAGE_NAME BOOT_IMAGE INITRAMFS" >&2
  exit 1
fi

CONFIG_FILE=$1
PKG_NAME=$2
BOOT_IMAGE=$3
INITRAMFS=$4

for name in "$PKG_NAME" "$BOOT_IMAGE" "$INITRAMFS"; do
  case "$name" in
    ''|*[!a-zA-Z0-9._+-]*)
      echo "error: invalid package or boot filename: $name" >&2
      exit 1
      ;;
  esac
done

if [ ! -f "$CONFIG_FILE" ]; then
  echo "error: boot configuration not found: $CONFIG_FILE" >&2
  exit 1
fi

BEGIN_MARKER="# BEGIN $PKG_NAME"
END_MARKER="# END $PKG_NAME"
TEMP_CONFIG=$(mktemp "${CONFIG_FILE}.XXXXXX")
trap 'rm -f "$TEMP_CONFIG"' 0
trap 'exit 1' HUP INT TERM

if ! awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" '
  {
    line = $0
    sub(/\r$/, "", line)
  }
  line == begin {
    if (managed) exit 1
    managed = 1
    next
  }
  line == end {
    if (!managed) exit 1
    managed = 0
    next
  }
  !managed { print }
  END { if (managed) exit 1 }
' "$CONFIG_FILE" > "$TEMP_CONFIG"; then
  echo "error: malformed $PKG_NAME block in $CONFIG_FILE; file not changed" >&2
  exit 1
fi

cat >> "$TEMP_CONFIG" <<EOF
$BEGIN_MARKER
[all]
kernel=$BOOT_IMAGE
auto_initramfs=1
initramfs $INITRAMFS followkernel
$END_MARKER
EOF

# Keep the permissions on filesystems that support them; FAT uses mount options.
chmod --reference="$CONFIG_FILE" "$TEMP_CONFIG"
mv -f "$TEMP_CONFIG" "$CONFIG_FILE"
