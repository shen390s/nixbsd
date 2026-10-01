# Installation {#ch-installation}

This chapter describes how to install NixBSD on a machine using the
bootable live ISO image.

## Building the ISO {#sec-building-iso}

Build the live ISO from the NixBSD flake:

```console
$ nix build .#packages.x86_64-linux.iso.isoImage
```

The resulting ISO is placed in `./result/iso/`.

## Booting the ISO {#sec-booting-iso}

### Physical Hardware {#sec-boot-physical}

Write the ISO to a USB drive:

```console
$ dd if=result/iso/nixbsd-*.iso of=/dev/sdX bs=4M status=progress
```

Then boot from the USB drive via your system's UEFI boot menu.

### QEMU with KVM and OVMF (Testing) {#sec-qemu-testing}

Create a virtual disk and a writable copy of the OVMF UEFI variables:

```console
$ qemu-img create -f qcow2 nixbsd-disk.qcow2 40G
$ cp /path/to/OVMF_VARS.fd ovmf_vars.fd
```

Boot the ISO:

```console
$ qemu-system-x86_64 \
    -machine q35,accel=kvm \
    -cpu host \
    -m 4096 \
    -smp 4 \
    -drive if=pflash,format=raw,readonly=on,file=/path/to/OVMF_CODE.fd \
    -drive if=pflash,format=raw,file=ovmf_vars.fd \
    -cdrom result/iso/nixbsd-*.iso \
    -drive file=nixbsd-disk.qcow2,format=qcow2,if=virtio \
    -boot d \
    -net nic,model=virtio \
    -net user,hostfwd=tcp::2222-:22 \
    -serial mon:stdio
```

The OVMF firmware path varies by distribution:

- NixOS/Nix: `$(nix build nixpkgs#OVMF.fd --print-out-paths)/FV/`
- Debian/Ubuntu: `/usr/share/OVMF/`
- Fedora: `/usr/share/edk2/ovmf/`

Remove `accel=kvm` and `-cpu host` if hardware virtualization is not
available (use `-cpu max` instead).

### Live Environment Credentials {#sec-live-credentials}

- Root: `root` / `nixbsd`
- User: `nixbsd` / `nixbsd`
- SSH: `ssh -p 2222 root@localhost` (when using QEMU user networking above)

## Installing to Disk {#sec-installing}

### Partitioning {#sec-partitioning}

The following example creates a GPT partition table with an EFI System
Partition and a UFS root partition. Adjust device names as appropriate
(`/dev/vtbd0` for virtio, `/dev/ada0` for AHCI/ATA).

```console
# gpart create -s gpt vtbd0
# gpart add -t efi -s 512m -l ESP vtbd0
# gpart add -t freebsd-ufs -l nixos vtbd0
```

::: {.note}
The partition labels are significant. The boot configuration references
the root filesystem as `/dev/gpt/nixos` and the EFI partition as
`/dev/msdosfs/ESP`. Use these labels or adjust your configuration
accordingly.
:::

### Formatting {#sec-formatting}

```console
# newfs_msdos -F 32 -c 1 -L ESP /dev/vtbd0p1
# newfs -U -L nixos /dev/vtbd0p2
```

::: {.note}
The `-c 1` flag sets 1 sector per cluster for FAT32, which is needed
to satisfy the minimum cluster count requirement on smaller partitions.
If the EFI partition is 512 MB or larger, you can omit `-c 1`.
:::

### Mounting {#sec-mounting}

```console
# mount /dev/vtbd0p2 /mnt
# mkdir -p /mnt/boot
# mount -t msdosfs /dev/vtbd0p1 /mnt/boot
```

### Generating Configuration {#sec-generate-config}

Generate the initial NixBSD configuration files by inspecting the
mounted target system:

```console
# nixos-generate-config --root /mnt
```

This creates:

- `/mnt/etc/nixos/configuration.nix` — Main system configuration
- `/mnt/etc/nixos/hardware-configuration.nix` — Detected hardware and filesystems

### Editing Configuration {#sec-edit-config}

Edit the main configuration file:

```console
# vim /mnt/etc/nixos/configuration.nix
```

Key settings to review:

```nix
{ config, lib, pkgs, ... }:
{
  imports = [ ./hardware-configuration.nix ];

  # Boot loader (should already be set)
  boot.loader.stand-freebsd.enable = true;

  # Set your hostname
  networking.hostName = "nixbsd";

  # Enable SSH
  services.sshd.enable = true;

  # Set root password
  users.users.root.initialPassword = "changeme";

  # Define a user account
  users.users.alice = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    initialPassword = "changeme";
  };

  # Locale (C.UTF-8 is built into FreeBSD's C library)
  i18n.defaultLocale = "C.UTF-8";

  system.stateVersion = "26.11";
}
```

### Running the Installer {#sec-run-installer}

Install the system to the mounted target:

```console
# nixos-install --root /mnt
```

You will be prompted to set a root password at the end. Use
`--no-root-passwd` to skip the password prompt (useful if you set
`initialPassword` in your configuration).

::: {.note}
The installer downloads packages from the binary cache. Ensure the live
environment has internet access. If the NixBSD binary cache is
unreachable, the installer will build packages from source, which takes
significantly longer.
:::

### Rebooting {#sec-reboot}

After installation completes, unmount and reboot:

```console
# umount /mnt/boot
# umount /mnt
# reboot
```

For QEMU, restart without the `-cdrom` and `-boot d` flags to boot from
the hard disk:

```console
$ qemu-system-x86_64 \
    -machine q35,accel=kvm \
    -cpu host \
    -m 4096 \
    -smp 4 \
    -drive if=pflash,format=raw,readonly=on,file=/path/to/OVMF_CODE.fd \
    -drive if=pflash,format=raw,file=ovmf_vars.fd \
    -drive file=nixbsd-disk.qcow2,format=qcow2,if=virtio \
    -net nic,model=virtio \
    -net user,hostfwd=tcp::2222-:22 \
    -serial mon:stdio
```

### Post-Install: Serial Console {#sec-serial-console}

To use a serial console (e.g., for headless QEMU with `-nographic` or
`-serial` options), create `/boot/loader.conf` on the installed system:

```console
# echo 'console="comconsole"' > /boot/loader.conf
```

This directs the FreeBSD boot loader and kernel to use the serial port
as the primary console.

## ZFS Installation {#sec-zfs-install}

NixBSD also supports ZFS as the root filesystem:

```console
# gpart create -s gpt vtbd0
# gpart add -t efi -s 512m -l ESP vtbd0
# gpart add -t freebsd-zfs -l nixos vtbd0

# newfs_msdos -F 32 -c 1 -L ESP /dev/vtbd0p1

# zpool create -o mountpoint=none -O mountpoint=/ -O atime=off -R /mnt zroot /dev/vtbd0p2
# zfs create -o mountpoint=/nix zroot/nix
# zfs create -o mountpoint=/var zroot/var
# zfs create -o mountpoint=/home zroot/home

# mkdir -p /mnt/boot
# mount -t msdosfs /dev/vtbd0p1 /mnt/boot

# nixos-generate-config --root /mnt
# nixos-install --root /mnt
```

Adjust `/mnt/etc/nixos/hardware-configuration.nix` to use
`fsType = "zfs"` if it was not auto-detected.

## Troubleshooting {#sec-install-troubleshooting}

### Activation fails on first boot {#sec-trouble-activation}

If the system reports "NixBSD system activation FAILED" and drops to a
rescue shell, this is typically caused by a dirty filesystem from a
non-graceful shutdown. From the rescue shell, run:

```console
bash-5.3# fsck -y /
bash-5.3# /run/current-system/activate
```

If activation then succeeds, the issue was `fsck` returning a non-zero
exit code after fixing the filesystem.

### nixos-rebuild reports "file nixbsd was not found" {#sec-trouble-nix-path}

The `NIX_PATH` environment variable is not set. This is configured
automatically on the live ISO but must be set on the installed system.

Add to your `configuration.nix`:

```nix
{ nixbsdSource, _nixbsdNixpkgsPath, ... }:
{
  environment.sessionVariables.NIX_PATH =
    "nixbsd=${nixbsdSource}:nixpkgs=${_nixbsdNixpkgsPath}";
}
```

Then rebuild. As a temporary workaround:

```console
# export NIX_PATH="nixbsd=/nix/store/...-source:nixpkgs=/nix/store/...-source"
```

The correct store paths can be found via:

```console
# nix eval --raw 'nixbsd#nixosConfigurations.base.config.environment.sessionVariables.NIX_PATH'
```

### mount_msdosfs: Invalid argument {#sec-trouble-msdosfs}

The `msdosfs` kernel module may not be loaded. The live ISO loads it
automatically, but if needed:

```console
# kldload msdosfs
```

### newfs_msdos: too few clusters for FAT32 {#sec-trouble-fat32-clusters}

Use `-c 1` to set 1 sector per cluster:

```console
# newfs_msdos -F 32 -c 1 -L ESP /dev/vtbd0p1
```

### Boot fails after install {#sec-trouble-boot-fail}

Verify the EFI boot files are in place:

```console
# ls /boot/efi/boot/bootx64.efi
# ls /boot/boot/lua/stand_config.lua
```

If missing, re-run the boot loader installer:

```console
# NIXOS_INSTALL_BOOTLOADER=1 /run/current-system/bin/switch-to-configuration boot
```

### Cannot find disk device {#sec-trouble-disk-device}

Device names depend on the controller type:

- Virtio: `/dev/vtbd0`
- AHCI/SATA: `/dev/ada0`
- NVMe: `/dev/nvd0` or `/dev/nda0`

Use `geom disk list` to see available disks.
