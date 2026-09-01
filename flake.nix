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
    {
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
