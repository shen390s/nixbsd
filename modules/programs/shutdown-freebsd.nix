{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.programs.shutdown;
in
{
  options = {
    programs.shutdown = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether to enable the `shutdown` and `poweroff` commands.
          These are generally setuid so that members of a certain group can run them.
          This is unrelated to `reboot` and `halt`, among others
        '';
      };

      group = mkOption {
        type = types.str;
        default = "wheel";
        description = ''
          Group which can run the `shutdown` and `poweroff` commands.
        '';
      };

      package = mkPackageOption pkgs [ "freebsd" "shutdown" ] { };
    };
  };

  config = mkIf cfg.enable {
    security.wrappers.shutdown = {
      setuid = true;
      owner = "root";
      inherit (cfg) group;
      permissions = "u+rx,g+rx,o+r";
      source = "${pkgs.freebsd.shutdown}/bin/shutdown";
    };

    security.wrappers.poweroff = {
      setuid = true;
      owner = "root";
      inherit (cfg) group;
      permissions = "u+rx,g+rx,o+r";
      source = "${pkgs.freebsd.shutdown}/bin/poweroff";
    };

    # FreeBSD shutdown/poweroff invokes /usr/bin/wall to broadcast messages.
    # Create the symlink so the wall notification works.
    system.activationScripts.usrbinwall = let
      wallPkg = if pkgs.freebsd ? wall then pkgs.freebsd.wall else pkgs.freebsd.bin;
    in ''
      mkdir -p /usr/bin
      if [ -e "${wallPkg}/bin/wall" ]; then
        ln -sfn "${wallPkg}/bin/wall" /usr/bin/.wall.tmp
        mv /usr/bin/.wall.tmp /usr/bin/wall
      fi
    '';
  };
}
