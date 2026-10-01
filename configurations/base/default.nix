{ config, lib, nixbsdSource, _nixbsdNixpkgsPath, ... }:
{
  nixpkgs.hostPlatform = "x86_64-freebsd";

  # Set NIX_PATH so nixos-rebuild can find <nixbsd> and <nixpkgs>
  environment.sessionVariables.NIX_PATH = "nixbsd=${nixbsdSource}:nixpkgs=${_nixbsdNixpkgsPath}";

  users.users.root.initialPassword = "toor";

  # Don't make me wait for an address...
  networking.dhcpcd.wait = "background";

  users.users.bestie = {
    isNormalUser = true;
    description = "your bestie";
    extraGroups = [ "wheel" ];
    inherit (config.users.users.root) initialPassword;
  };

  services.sshd.enable = true;
  boot.loader.stand-freebsd.enable = true;

  fileSystems."/" = {
    device = "/dev/gpt/nixos";
    fsType = "ufs";
  };

  fileSystems."/boot" = {
    device = "/dev/msdosfs/ESP";
    fsType = "msdosfs";
  };

  virtualisation.vmVariant.virtualisation.diskImage = "./${config.system.name}.qcow2";
}
