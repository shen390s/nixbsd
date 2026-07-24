#! @runtimeShell@
# shellcheck shell=bash
# Generate NixBSD configuration by detecting hardware and filesystems.
# Adapted from nixos-generate-config for FreeBSD/NixBSD systems.

set -euo pipefail

export PATH="@path@:$PATH"

outDir="/etc/nixos"
rootDir=""
force=0
noFilesystems=0
showHardwareConfig=0

usage() {
  cat <<EOF
Usage: nixbsd-generate-config [OPTIONS]

Generate NixBSD configuration files (configuration.nix and
hardware-configuration.nix) by inspecting the running system.

Options:
  --dir DIR         Write configuration files to DIR (default: /etc/nixos)
  --root DIR        Treat DIR as the root of the mounted system
  --force           Overwrite existing configuration.nix
  --no-filesystems  Skip filesystem detection
  --show-hardware-config
                    Print hardware config to stdout instead of writing files
  --help            Show this help message
EOF
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)
      usage
      ;;
    --dir)
      shift
      outDir="$1"
      ;;
    --root)
      shift
      rootDir="${1%/}"  # strip trailing slash
      if [ "$rootDir" = "/" ]; then
        echo "Error: no need to specify '/' with --root, it is the default" >&2
        exit 1
      fi
      ;;
    --force)
      force=1
      ;;
    --no-filesystems)
      noFilesystems=1
      ;;
    --show-hardware-config)
      showHardwareConfig=1
      ;;
    *)
      echo "Error: unrecognized argument '$1'" >&2
      exit 1
      ;;
  esac
  shift
done

# --- Helper functions ---

# Find a stable device path for a given device.
# On FreeBSD, prefer /dev/gpt/*, /dev/ufsid/*, /dev/msdosfs/* over raw device nodes.
find_stable_dev_path() {
  local dev="$1"

  # If it's already a stable path, keep it
  case "$dev" in
    /dev/gpt/*|/dev/ufsid/*|/dev/msdosfs/*|/dev/zvol/*|/dev/label/*)
      echo "$dev"
      return
      ;;
  esac

  # Skip non-device paths
  if [ "${dev#/dev/}" = "$dev" ]; then
    echo "$dev"
    return
  fi

  # Try to find the device via GEOM labels
  # Check /dev/gpt/ first (GPT partition labels)
  if [ -d /dev/gpt ]; then
    for label in /dev/gpt/*; do
      if [ -e "$label" ] && [ "$(stat -f '%r' "$label" 2>/dev/null)" = "$(stat -f '%r' "$dev" 2>/dev/null)" ]; then
        echo "$label"
        return
      fi
    done
  fi

  # Check /dev/ufsid/ (UFS filesystem IDs)
  if [ -d /dev/ufsid ]; then
    for label in /dev/ufsid/*; do
      if [ -e "$label" ] && [ "$(stat -f '%r' "$label" 2>/dev/null)" = "$(stat -f '%r' "$dev" 2>/dev/null)" ]; then
        echo "$label"
        return
      fi
    done
  fi

  # Check /dev/msdosfs/ (FAT filesystem labels)
  if [ -d /dev/msdosfs ]; then
    for label in /dev/msdosfs/*; do
      if [ -e "$label" ] && [ "$(stat -f '%r' "$label" 2>/dev/null)" = "$(stat -f '%r' "$dev" 2>/dev/null)" ]; then
        echo "$label"
        return
      fi
    done
  fi

  # Fallback to the raw device path
  echo "$dev"
}

# Escape special characters for Nix strings
nix_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//\$/\\\$}"
  echo "$s"
}

# --- Hardware detection ---

detect_hardware() {
  local attrs=""
  local imports=""

  # Detect CPU architecture
  local arch
  arch="$(sysctl -n hw.machine_arch 2>/dev/null || echo "x86_64")"
  case "$arch" in
    amd64) arch="x86_64" ;;
    arm64|aarch64) arch="aarch64" ;;
  esac
  attrs="${attrs}  nixpkgs.hostPlatform = lib.mkDefault \"${arch}-freebsd\";\n"

  # Detect virtualization
  local vm_guest
  vm_guest="$(sysctl -n kern.vm_guest 2>/dev/null || echo "none")"
  case "$vm_guest" in
    xen)
      attrs="${attrs}\n  # Xen guest\n"
      ;;
    hv)
      attrs="${attrs}\n  # Hyper-V guest\n"
      ;;
    vmware)
      attrs="${attrs}\n  # VMware guest\n"
      ;;
    kvm)
      attrs="${attrs}\n  # KVM/QEMU guest\n"
      ;;
    bhyve)
      attrs="${attrs}\n  # Bhyve guest\n"
      ;;
    vbox)
      attrs="${attrs}\n  # VirtualBox guest\n"
      ;;
  esac

  # Detect if ZFS is in use (check for loaded module or active pools)
  if kldstat -q -m zfs 2>/dev/null || zpool list -H 2>/dev/null | grep -q .; then
    attrs="${attrs}\n  boot.supportedFilesystems = [ \"zfs\" ];\n"
  fi

  echo "$attrs"
}

# --- Filesystem detection ---

detect_filesystems() {
  if [ "$noFilesystems" -eq 1 ]; then
    return
  fi

  local fs_config=""

  # Parse mount output on FreeBSD
  # Format: /dev/ada0p2 on / (ufs, local, journaled, soft-updates)
  mount -p 2>/dev/null | while IFS=$'\t' read -r device mountpoint fstype options dump pass; do
    # mount -p gives fstab-style output: device mountpoint fstype options dump pass

    # Apply root prefix stripping
    if [ -n "$rootDir" ]; then
      case "$mountpoint" in
        "${rootDir}"*)
          mountpoint="${mountpoint#"$rootDir"}"
          [ -z "$mountpoint" ] && mountpoint="/"
          ;;
        *)
          continue
          ;;
      esac
    fi

    # Skip special/virtual filesystems
    case "$fstype" in
      devfs|fdescfs|procfs|linprocfs|linsysfs|tmpfs|nullfs)
        continue
        ;;
    esac

    # Skip /dev, /proc, /sys type mounts
    case "$mountpoint" in
      /dev|/dev/*|/proc|/proc/*|/sys|/sys/*)
        continue
        ;;
    esac

    # Find a stable device path
    local stable_dev
    if [ "$fstype" = "zfs" ]; then
      # For ZFS, use the dataset name directly
      stable_dev="$device"
    else
      stable_dev="$(find_stable_dev_path "$device")"
    fi

    cat <<NIXFS
  fileSystems."$(nix_escape "$mountpoint")" =
    { device = "$(nix_escape "$stable_dev")";
      fsType = "$fstype";
    };

NIXFS
  done

  # Detect swap devices
  if swapinfo -h 2>/dev/null | tail -n +2 | grep -q .; then
    echo "  swapDevices ="
    echo -n "    ["
    local first=1
    swapinfo -h 2>/dev/null | tail -n +2 | while read -r device _ _ _ _; do
      local stable_dev
      stable_dev="$(find_stable_dev_path "$device")"
      if [ "$first" -eq 1 ]; then
        first=0
      fi
      echo -n " { device = \"$(nix_escape "$stable_dev")\"; }"
    done
    echo " ];"
    echo ""
  else
    echo "  swapDevices = [ ];"
    echo ""
  fi
}

# --- Generate hardware-configuration.nix ---

generate_hardware_config() {
  local hw_attrs
  hw_attrs="$(detect_hardware)"

  cat <<EOF
# Do not modify this file!  It was generated by 'nixbsd-generate-config'
# and may be overwritten by future invocations.  Please make changes
# to /etc/nixos/configuration.nix instead.
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [ ];

$(echo -e "$hw_attrs")
$(detect_filesystems)}
EOF
}

# --- Generate configuration.nix ---

generate_configuration() {
  cat <<'EOF'
# Edit this configuration file to define what should be installed on
# your system. Help is available in the NixBSD documentation.
{ config, lib, pkgs, ... }:

{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
    ];

  # Use the FreeBSD stand boot loader.
  boot.loader.stand-freebsd.enable = true;

  # networking.hostName = "nixbsd"; # Define your hostname.

  # Set your time zone.
  # time.timeZone = "America/New_York";

  # Define a user account. Don't forget to set a password with 'passwd'.
  # users.users.alice = {
  #   isNormalUser = true;
  #   extraGroups = [ "wheel" ]; # Enable 'sudo' for the user.
  # };

  # List packages installed in system profile.
  # environment.systemPackages = with pkgs; [
  #   vim
  #   git
  # ];

  # Enable the OpenSSH daemon.
  # services.sshd.enable = true;

  # This option defines the first version of NixBSD installed on this
  # particular machine, and is used to maintain compatibility with
  # application data (e.g. databases) created on older versions.
  # Most users should NEVER change this value after the initial install.
  system.stateVersion = "@stateVersion@";
}
EOF
}

# --- Main ---

if [ "$showHardwareConfig" -eq 1 ]; then
  generate_hardware_config
  exit 0
fi

# Determine output directory
if [ "$outDir" = "/etc/nixos" ] && [ -n "$rootDir" ]; then
  outDir="${rootDir}${outDir}"
fi

# Create output directory
mkdir -p "$outDir"

# Write hardware-configuration.nix (always overwritten)
hwFile="${outDir}/hardware-configuration.nix"
echo "writing ${hwFile}..." >&2
generate_hardware_config > "$hwFile"

# Write configuration.nix (only if it doesn't exist or --force)
confFile="${outDir}/configuration.nix"
if [ "$force" -eq 1 ] || [ ! -e "$confFile" ]; then
  echo "writing ${confFile}..." >&2
  generate_configuration > "$confFile"
else
  echo "warning: not overwriting existing ${confFile}" >&2
fi

echo "Done. Edit ${confFile} to customize your system configuration." >&2
