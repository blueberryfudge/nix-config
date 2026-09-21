{
  description = "Base nix-darwin configuration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-25.11-darwin";
    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    determinate.url = "https://flakehub.com/f/DeterminateSystems/determinate/3";
    darwin = {
      url = "github:nix-darwin/nix-darwin/nix-darwin-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-homebrew.url = "github:zhaofengli/nix-homebrew";
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      darwin,
      home-manager,
      nix-homebrew,
      determinate,
      ...
    }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };
      # Custom packages built from this repo, discoverable as `.#<name>`.
      packagesFor = system: {
        pi = (pkgsFor system).callPackage ./packages/pi { };
      };
    in
    {
      packages = forAllSystems packagesFor;

      # `nix run .#update-packages` runs the `passthru.updateScript` of every
      # custom package that defines one (bumps version + hashes in place).
      apps = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          packages = packagesFor system;
          updateCommandFor =
            name:
            let
              passthru = packages.${name}.passthru or { };
            in
            if passthru ? updateScript then
              ''
                echo "-> Updating ${name}..."
                ${toString passthru.updateScript}
              ''
            else
              "echo '-> Pinned ${name} (no updateScript; skipped)'";
          updatePackages = pkgs.writeShellScriptBin "update-packages" ''
            set -euo pipefail
            export repo_root="$(${pkgs.git}/bin/git rev-parse --show-toplevel 2>/dev/null || ${pkgs.coreutils}/bin/pwd)"
            cd "$repo_root"
            # Keep the nested `nix build` isolated from stale system-only settings.
            export NIX_CONF_DIR="''${TMPDIR:-/tmp}/nix-update-conf"
            ${pkgs.coreutils}/bin/mkdir -p "$NIX_CONF_DIR"
            printf '%s\n' 'experimental-features = nix-command flakes' > "$NIX_CONF_DIR/nix.conf"
            echo "Checking package updates..."
            ${builtins.concatStringsSep "\n" (map updateCommandFor (builtins.attrNames packages))}
            echo "Done!"
          '';
        in
        {
          update-packages = {
            type = "app";
            program = "${updatePackages}/bin/update-packages";
          };
        }
      );

      lib = {
        mkSystem = {
          user,
          system ? "aarch64-darwin",
          homeModule,
          hostModule,
          extraOverlays ? [],
          gitConfig ? {},
          nixDirectory ? "~/.config/nix-config",
        }:
        let
          overlays = extraOverlays;

          nixfiles = ./.;
        in
        darwin.lib.darwinSystem {
          inherit system;
          specialArgs = {
            inherit inputs nixfiles user;
            inherit hostModule;
          };
          modules = [
            {nixpkgs.overlays = overlays; }
            home-manager.darwinModules.home-manager
            nix-homebrew.darwinModules.nix-homebrew
            determinate.darwinModules.default
            hostModule
            (import ./modules/shared/homemanager.nix {
              inherit nixfiles user nixDirectory homeModule inputs gitConfig;
            })
          ];
        };
      };

      darwinConfigurations.personal-mac = self.lib.mkSystem {
        user = "x";
        homeModule = ./hosts/personal/home.nix;
        hostModule = ./hosts/personal;
        gitConfig = {
          userName = "x";
          userEmail = "edvard.bgs@gmail.com";
          signingKey = "/Users/x/.ssh/id_ed25519";
          workSSHKey = null;
          personalSSHKey = "/Users/x/.ssh/id_ed25519";
          enableLunarUrls = false;
          enablePersonalAlias = false;
          user = "x";
        };
      };
    };
  }
