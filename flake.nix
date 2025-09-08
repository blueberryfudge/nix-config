{
  description = "Multi-machine nix-darwin configurations";

  inputs = {
    #nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
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

    lunar-tools = {
      url = "git+ssh://git@github.com/lunarway/lw-nix?ref=feat/zsh-plugin";
    };
  };

  outputs =
    inputs@{
      self,
      #nixpkgs-unstable, # TODO: inject as option
      nixpkgs,
      darwin,
      home-manager,
      nix-homebrew,
      flake-utils,
      helix,
      lunar-tools,
      ...
    }:
    let
      overlays = [
        helix.overlays.default
        lunar-tools.overlays.default
      ];

      nixfiles = ./.;
      systemConfigs = {
        "work-mac" = {
          system = "aarch64-darwin";
          user = "edb";
          nixDirectory = "~/.config/nix-config";
          homeModule = ./hosts/work/home.nix;
          hostModule = ./hosts/work;
          enableHomebrew = false;

          gitConfig = {
            userName = "Edvard Boguslavskij";
            userEmail = "edb@lunar.app";
            signingKey = "/Users/edb/.ssh/github.pub";
            workSSHKey = "/Users/edb/.ssh/github";
            personalSSHKey = "/Users/edb/.ssh/id_ed25519";
            enablePersonalAlias = true;
            user = "edb";
          };
        };

        "personal-mac" = {
          system = "aarch64-darwin";
          user = "x";
          nixDirectory = "~/.config/nix-config";
          homeModule = ./hosts/personal/home.nix;
          hostModule = ./hosts/personal;
          enableHomebrew = false;

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
      mkDarwinSystem =
        hostname: config:
        darwin.lib.darwinSystem {
          system = config.system;
          specialArgs = {
            inherit inputs nixfiles;
            user = config.user;
          };
          modules = [
            { nixpkgs.overlays = overlays; }
            home-manager.darwinModules.home-manager
            #nix-homebrew.darwinModules.nix-homebrew
            config.hostModule
            (import ./modules/shared/homemanager.nix {
              inherit nixfiles;
              user = config.user;
              nixDirectory = config.nixDirectory;
              homeModule = config.homeModule;
              inputs = inputs;
              enableHomebrew = config.enableHomebrew;
              gitConfig = config.gitConfig;
            })
          ];
        };

    in
    {
      darwinConfigurations = builtins.mapAttrs mkDarwinSystem systemConfigs;
    };
}
