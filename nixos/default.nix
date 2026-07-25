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

  # Fetch mini-tmpfiles source using the locked revision.
  # On the live ISO this resolves from the local store (no network needed).
  mini-tmpfiles-src = builtins.fetchTree {
    type = "github";
    owner = lock.nodes.mini-tmpfiles.locked.owner;
    repo = lock.nodes.mini-tmpfiles.locked.repo;
    rev = lock.nodes.mini-tmpfiles.locked.rev;
    narHash = lock.nodes.mini-tmpfiles.locked.narHash;
  };

  # Construct a fake flake output that provides the overlay,
  # matching what the flake evaluation would produce.
  mini-tmpfiles-flake = {
    overlays.default = final: prev: {
      mini-tmpfiles = final.callPackage "${mini-tmpfiles-src}/package.nix" { };
    };
  };

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
