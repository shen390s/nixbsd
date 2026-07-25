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
  # Read the flake lock to get pinned input revisions for offline use.
  lock = builtins.fromJSON (builtins.readFile ../flake.lock);

  # Use builtins.getFlake to properly evaluate the mini-tmpfiles flake.
  # The narHash ensures this resolves from the local store on the ISO
  # without network access.
  mini-tmpfiles-flake = builtins.getFlake
    "github:${lock.nodes.mini-tmpfiles.locked.owner}/${lock.nodes.mini-tmpfiles.locked.repo}/${lock.nodes.mini-tmpfiles.locked.rev}";

  eval = import ../lib/eval-config.nix {
    inherit system;
    specialArgs = {
      cppnixFlake = null;
      inherit mini-tmpfiles-flake;
      nixbsdSource = ../.;
    };
    modules = [
      configuration
      # Disable the cppnix overlay (not available without the flake)
      # but keep mini-tmpfiles overlay active since we fetched it above.
      { nixpkgs.overrideNix = false; }
    ];
  };
in
{
  inherit (eval) config options pkgs;
  system = eval.config.system.build.toplevel;
  vm = eval.config.system.build.vm;
}
