{
  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixos-unstable-small/nixexprs.tar.xz";
    cppnix = {
      url = "github:nixos/nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    mini-tmpfiles = {
      url = "github:nixos-bsd/mini-tmpfiles";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-compat.url = "https://flakehub.com/f/edolstra/flake-compat/1.tar.gz";
  };

  nixConfig = {
    extra-substituters = [
      "https://attic.shenrs.eu/nixbsd"
    ];
    extra-trusted-public-keys = [
      "nixbsd:CVc5jh1+of1Qy1Hdpf7Qi3pweICXIeP8kf+/DTu9ocg="
    ];
  };

  outputs =
    {
      self,
      nixpkgs,
      cppnix ? null,
      mini-tmpfiles,
      ...
    }:
    let
      inherit (nixpkgs) lib;

      makePkgs = system: import nixpkgs { inherit system; };
      forAllSystems = lib.genAttrs lib.systems.flakeExposed;

      configBase = ./configurations;
      makeSystem =
        name: module:
        self.lib.nixbsdSystem {
          modules = [
            module
            {
              networking.hostName = "nixbsd-${name}";
              system.configurationRevision = self.rev or self.dirtyRev or "dirty";
            }
          ];
        };

      makeImage =
        buildPlatform: conf:
        let
          extended = conf.extendModules {
            modules = [
              {
                config.nixpkgs.buildPlatform = buildPlatform;
              }
            ];
          };
        in
        extended.config.system.build
        // {
          # appease `nix flake show`
          type = "derivation";
          name = "system-build";

          closureInfo = extended.pkgs.closureInfo {
            rootPaths = [ extended.config.system.build.toplevel.drvPath ];
          };
          vmClosureInfo = extended.pkgs.closureInfo {
            rootPaths = [ extended.config.system.build.vm.drvPath ];
          };
          isoClosureInfo = lib.optionalAttrs (extended.config.system.build ? isoImage) (
            extended.pkgs.closureInfo {
              rootPaths = [ extended.config.system.build.isoImage.drvPath ];
            }
          );
          system = extended.config.system.build.toplevel;
          inherit (extended) pkgs config;
        };
    in
    {
      lib.nixbsdSystem =
        args:
        import ./lib/eval-config.nix (
          args
          // {
            inherit (nixpkgs) lib;
            nixpkgsPath = nixpkgs.outPath;
            specialArgs = {
              cppnixFlake = cppnix;
              mini-tmpfiles-flake = mini-tmpfiles;
              nixbsdSource = self.outPath;
            }
            // (args.specialArgs or { });
          }
          // lib.optionalAttrs (!args ? system) { system = null; }
        );

      nixosConfigurations = lib.mapAttrs (name: _: makeSystem name (configBase + "/${name}")) (
        builtins.readDir configBase
      );

      # Structured image outputs keyed by target platform and configuration name.
      # Usage:
      #   nix build .#images.freebsd-x86_64.iso.isoImage
      #   nix build .#images.freebsd-x86_64.base.vm
      #   nix build .#images.openbsd-x86_64.openbsd-base.vm
      images =
        let
          # Detect the current system for build platform (the machine doing the build)
          currentSystem = builtins.currentSystem or "x86_64-linux";

          # Group configurations by their target platform
          targetPlatformOf = name: conf:
            let hostPlatform = conf.config.nixpkgs.hostPlatform.system or "x86_64-freebsd";
            in if lib.hasInfix "freebsd" hostPlatform then "freebsd-x86_64"
               else if lib.hasInfix "openbsd" hostPlatform then "openbsd-x86_64"
               else hostPlatform;

          buildImage = name: makeImage currentSystem (self.nixosConfigurations.${name});

          # Build a map: { freebsd-x86_64 = { iso = ...; base = ...; }; openbsd-x86_64 = { ... }; }
          allImages = lib.foldlAttrs (acc: name: conf:
            let
              target = targetPlatformOf name conf;
              image = buildImage name;
            in acc // {
              ${target} = (acc.${target} or {}) // { ${name} = image; };
            }
          ) {} self.nixosConfigurations;
        in allImages;

      # Standard packages output (keyed by build platform, for Hydra/CI compatibility).
      # Note: the top-level key is the BUILD platform (the machine compiling),
      # not the target. E.g. packages.x86_64-linux.iso builds a FreeBSD ISO on Linux.
      packages = forAllSystems (
        system:
        lib.mapAttrs (name: makeImage system) self.nixosConfigurations
        // {
          tools = nixpkgs.legacyPackages.${system}.callPackages ./modules/installer/tools/package.nix { };
        }
      );

      formatter = forAllSystems (system: (makePkgs system).nixfmt-tree);

      hydraJobs = lib.mapAttrs (
        name: attrs:
        {
          inherit (attrs) vm;
        }
        // lib.optionalAttrs (attrs ? systemImage && attrs.systemImage != null) {
          inherit (attrs) systemImage;
        }
        // lib.optionalAttrs (attrs ? isoImage) {
          inherit (attrs) isoImage;
        }
      ) self.packages.x86_64-linux;
    };
}
