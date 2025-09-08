{
  description = "Base nix-darwin configuration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    darwin = {
      url = "github:nix-darwin/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-homebrew.url = "github:zhaofengli/nix-homebrew";
    flake-utils.url = "github:numtide/flake-utils";
    helix.url = "github:helix-editor/helix";
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      darwin,
      home-manager,
      nix-homebrew,
      flake-utils,
      helix,
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
          enableHomeBrew ? false
        }:
        let
          overlays = [
            helix.overlays.default
          ] ++ extraOverlays;

          nixfiles = ./.;
        in
        darwin.lib.darwinSystem {
          inherit system;
          specialArgs = {
            inherit inputs nixfiles user;
          };
          modules = [
            {nixpkgs.overlays = overlays; }
            home-manager.darwinModules.home-manager
            hostModule
            (import ./modules/shared/homemanager.nix {
              inherit nixfiles user nixDirectory homeModule inputs enableHomeBrew gitConfig;
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
