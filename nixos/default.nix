# Entry point for non-flake evaluation of NixBSD configurations.
# Used by nixos-install, nixos-rebuild, and other tools via:
#   nix-build '<nixbsd/nixos>' -A system -I nixos-config=/etc/nixos/configuration.nix
#
# This avoids the flake-compat path (default.nix) which requires network
# access to fetch flake inputs.
#
# Expects NIX_PATH to contain:
#   nixbsd=<path-to-nixbsd-source>
#   nixpkgs=<path-to-nixpkgs-source>
#   nixos-config=<path-to-configuration.nix> (or passed via -I)

{ configuration ? <nixos-config>
, system ? builtins.currentSystem
}:

let
  eval = import ../lib/eval-config.nix {
    inherit system;
    modules = [
      configuration
    ];
  };
in
{
  inherit (eval) config options pkgs;
  system = eval.config.system.build.toplevel;
  vm = eval.config.system.build.vm;
}
