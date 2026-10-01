#!/bin/sh
# nixbsd-install-to-disk — Partition, format, and install NixBSD to a disk.
#
# Usage: nixbsd-install-to-disk /dev/ada0
#
# This script automates the full installation process:
#   1. Destroy any existing partition table
#   2. Create GPT with EFI System Partition + UFS root
#   3. Format both partitions
#   4. Mount to /mnt
#   5. Run nixos-generate-config --root /mnt
#   6. Run nixos-install --root /mnt
#
# Designed for use in the NixBSD live ISO environment.

set -e

usage() {
  echo "Usage: nixbsd-install-to-disk <disk-device>"
  echo ""
  echo "Example: nixbsd-install-to-disk /dev/ada0"
  echo "         nixbsd-install-to-disk /dev/vtbd0"
  echo ""
  echo "Options:"
  echo "  --yes           Skip confirmation prompt"
  echo "  --no-install    Only partition and generate config, don't run nixos-install"
  echo "  --mount-point   Mount point (default: /mnt)"
  echo "  --help          Show this help"
  exit 0
}

DISK=""
YES=0
NO_INSTALL=0
MOUNT_POINT="/mnt"

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)
      usage
      ;;
    --yes|-y)
      YES=1
      ;;
    --no-install)
      NO_INSTALL=1
      ;;
    --mount-point)
      shift
      MOUNT_POINT="$1"
      ;;
    /dev/*)
      DISK="$1"
      ;;
    *)
      echo "Error: unknown argument '$1'" >&2
      exit 1
      ;;
  esac
  shift
done

if [ -z "$DISK" ]; then
  echo "Error: no disk device specified." >&2
  echo "" >&2
  echo "Available disks:" >&2
  # List available disk devices
  if command -v geom >/dev/null 2>&1; then
    geom disk list 2>/dev/null | grep -E "^Geom name:|Mediasize:" | paste - - || true
  elif [ -d /dev ]; then
    ls /dev/ada* /dev/da* /dev/vtbd* /dev/nvd* 2>/dev/null | grep -v '[ps][0-9]' || true
  fi
  echo "" >&2
  echo "Usage: nixbsd-install-to-disk /dev/<disk>" >&2
  exit 1
fi

# Verify the disk exists
if [ ! -e "$DISK" ]; then
  echo "Error: disk device '$DISK' does not exist." >&2
  exit 1
fi

# Confirmation
if [ "$YES" -eq 0 ]; then
  echo "WARNING: This will DESTROY all data on $DISK!"
  echo ""
  echo "The following partition layout will be created:"
  echo "  p1: EFI System Partition (ESP) - 512 MB, FAT, label=ESP"
  echo "  p2: Root filesystem           - remainder, UFS, label=nixos"
  echo ""
  printf "Type 'yes' to continue: "
  read -r answer
  if [ "$answer" != "yes" ]; then
    echo "Aborted."
    exit 1
  fi
fi

echo "==> Destroying existing partition table on $DISK..."
gpart destroy -F "$DISK" 2>/dev/null || true

echo "==> Creating GPT partition table on $DISK..."
gpart create -s gpt "$DISK"

echo "==> Creating EFI System Partition (512 MB)..."
gpart add -t efi -s 512m -l ESP "$DISK"

echo "==> Creating UFS root partition (remaining space)..."
gpart add -t freebsd-ufs -l nixos "$DISK"

# Determine partition device names
# For ada0 -> ada0p1, ada0p2; for vtbd0 -> vtbd0p1, vtbd0p2
ESP_DEV="${DISK}p1"
ROOT_DEV="${DISK}p2"

echo "==> Formatting ESP ($ESP_DEV) as FAT..."
newfs_msdos -L ESP "$ESP_DEV"

echo "==> Formatting root partition ($ROOT_DEV) as UFS..."
newfs -U -L nixos "$ROOT_DEV"

echo "==> Mounting filesystems at $MOUNT_POINT..."
mkdir -p "$MOUNT_POINT"
mount "$ROOT_DEV" "$MOUNT_POINT"
mkdir -p "$MOUNT_POINT/boot"
mount -t msdosfs "$ESP_DEV" "$MOUNT_POINT/boot"

echo "==> Filesystems mounted:"
echo "  $ROOT_DEV -> $MOUNT_POINT"
echo "  $ESP_DEV  -> $MOUNT_POINT/boot"
echo ""

echo "==> Running nixos-generate-config --root $MOUNT_POINT..."
nixos-generate-config --root "$MOUNT_POINT"

echo ""
echo "==> Generated configuration files:"
echo "  $MOUNT_POINT/etc/nixos/configuration.nix"
echo "  $MOUNT_POINT/etc/nixos/hardware-configuration.nix"
echo ""

if [ "$NO_INSTALL" -eq 1 ]; then
  echo "Skipping nixos-install (--no-install specified)."
  echo ""
  echo "To complete installation manually:"
  echo "  1. Edit $MOUNT_POINT/etc/nixos/configuration.nix"
  echo "  2. Run: nixos-install --root $MOUNT_POINT"
  exit 0
fi

echo "==> Running nixos-install --root $MOUNT_POINT..."
nixos-install --root "$MOUNT_POINT"

echo ""
echo "==> Installation complete!"
echo ""
echo "You can now reboot into your new NixBSD system."
echo "  # umount -R $MOUNT_POINT"
echo "  # reboot"
