# Installation {#ch-installation}

This chapter describes how to install NixBSD on a machine using the
bootable live ISO image.

## Building the ISO {#sec-building-iso}

Build the live ISO from the NixBSD flake:

```console
$ nix build .#packages.x86_64-linux.iso.isoImage
```

The resulting ISO is placed in `./result/`.

## Booting the ISO {#sec-booting-iso}

### Physical Hardware {#sec-boot-physical}

Write the ISO to a USB drive:

```console
$ dd if=result/nixbsd-*.iso of=/dev/sdX bs=4M status=progress
```

Then boot from the USB drive via your system's UEFI boot menu.

### QEMU with EFI (Testing) {#sec-qemu-testing}

Create a virtual disk and boot the ISO with OVMF EFI firmware:

```console
$ qemu-img create -f qcow2 nixbsd-disk.qcow2 20G

$ cp /usr/share/OVMF/OVMF_VARS.fd ovmf_vars.fd

$ qemu-system-x86_64 \
    -m 2048 \
    -smp 2 \
    -enable-kvm \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE.fd \
    -drive if=pflash,format=raw,file=ovmf_vars.fd \
    -cdrom result/nixbsd-*.iso \
    -drive file=nixbsd-disk.qcow2,format=qcow2,if=virtio \
    -boot d \
    -net nic,model=virtio \
    -net user,hostfwd=tcp::2222-:22 \
    -serial mon:stdio
```

The OVMF firmware path varies by distribution:

- Debian/Ubuntu: `/usr/share/OVMF/OVMF_CODE.fd`
- Fedora: `/usr/share/edk2/ovmf/OVMF_CODE.fd`
- NixOS: available via `pkgs.OVMF.fd`

Remove `-enable-kvm` if hardware virtualization is not available.

### Live Environment Credentials {#sec-live-credentials}

- Root: `root` / `nixbsd`
- User: `nixbsd` / `nixbsd`
- SSH: `ssh -p 2222 root@localhost` (when using QEMU port forwarding above)

## Installing to Disk {#sec-installing}

### Partitioning {#sec-partitioning}

The following example creates a GPT partition table with an EFI System
Partition and a UFS root partition. Adjust device names as appropriate
(`/dev/vtbd0` for virtio, `/dev/ada0` for AHCI/ATA).

```console
# gpart create -s gpt vtbd0
# gpart add -t efi -s 1048576 -l efi vtbd0
# gpart add -t freebsd-ufs -l nixbsd vtbd0
```

::: {.note}
The EFI partition size is specified in sectors (512 bytes each).
1048576 sectors = 512 MB, which is sufficient for FAT32 formatting.
:::

### Formatting {#sec-formatting}

```console
# newfs_msdos -F 32 -c 1 -L EFI /dev/vtbd0p1
# newfs -U -L nixbsd /dev/vtbd0p2
```

::: {.note}
The `-c 1` flag sets 1 sector per cluster for FAT32, which is needed
to satisfy the minimum cluster count requirement on smaller partitions.
:::

### Mounting {#sec-mounting}

```console
# mount /dev/vtbd0p2 /mnt
# mkdir -p /mnt/boot/efi
# mount -t msdosfs /dev/vtbd0p1 /mnt/boot/efi
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
{
  # Boot loader (should already be set)
  boot.loader.stand-freebsd.enable = true;

  # Set your hostname
  networking.hostName = "nixbsd";

  # Enable SSH
  services.sshd.enable = true;

  # Define a user account
  users.users.alice = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    initialPassword = "changeme";
  };
}
```

### Running the Installer {#sec-run-installer}

Install the system to the mounted target:

```console
# nixos-install --root /mnt
```

You will be prompted to set a root password at the end.

### Rebooting {#sec-reboot}

After installation completes:

```console
# reboot
```

For QEMU, restart without the `-cdrom` flag and change `-boot d` to
`-boot c` to boot from the hard disk:

```console
$ qemu-system-x86_64 \
    -m 2048 \
    -smp 2 \
    -enable-kvm \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE.fd \
    -drive if=pflash,format=raw,file=ovmf_vars.fd \
    -drive file=nixbsd-disk.qcow2,format=qcow2,if=virtio \
    -boot c \
    -net nic,model=virtio \
    -net user,hostfwd=tcp::2222-:22 \
    -serial mon:stdio
```

## ZFS Installation {#sec-zfs-install}

NixBSD also supports ZFS as the root filesystem:

```console
# gpart create -s gpt vtbd0
# gpart add -t efi -s 1048576 -l efi vtbd0
# gpart add -t freebsd-zfs -l nixbsd vtbd0

# newfs_msdos -F 32 -c 1 -L EFI /dev/vtbd0p1

# zpool create -o mountpoint=none -O mountpoint=/ -O atime=off -R /mnt zroot /dev/vtbd0p2
# zfs create -o mountpoint=/nix zroot/nix
# zfs create -o mountpoint=/var zroot/var
# zfs create -o mountpoint=/home zroot/home

# mkdir -p /mnt/boot/efi
# mount -t msdosfs /dev/vtbd0p1 /mnt/boot/efi

# nixos-generate-config --root /mnt
# nixos-install --root /mnt
```

## Troubleshooting {#sec-install-troubleshooting}

### nixos-install reports file nixbsd was not found {#sec-trouble-nix-path}

The `NIX_PATH` environment variable is not set. This is configured
automatically on the live ISO. If you are in a custom environment,
set it manually:

```console
# export NIX_PATH="nixbsd=/path/to/nixbsd-source:nixpkgs=/path/to/nixpkgs"
```

### mount_msdosfs Invalid argument {#sec-trouble-msdosfs}

The `msdosfs` kernel module may not be loaded. The live ISO loads it
automatically, but if needed:

```console
# kldload msdosfs
```

### newfs_msdos too few clusters for FAT32 {#sec-trouble-fat32-clusters}

Use `-c 1` to set 1 sector per cluster:

```console
# newfs_msdos -F 32 -c 1 -L EFI /dev/vtbd0p1
```

Alternatively, use FAT16 which has no minimum cluster count:

```console
# newfs_msdos -F 16 -L EFI /dev/vtbd0p1
```

### Boot fails after install {#sec-trouble-boot-fail}

Check that the EFI boot entry was created correctly. From the installed
system, verify with `efibootmgr -v`.

### Cannot find disk device {#sec-trouble-disk-device}

Device names depend on the controller type:

- Virtio: `/dev/vtbd0`
- AHCI/SATA: `/dev/ada0`
- NVMe: `/dev/nvd0` or `/dev/nda0`

Use `geom disk list` to see available disks.
