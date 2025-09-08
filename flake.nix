{
  description = "Multi-machine nix-darwin configurations";

  inputs = {
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
    nixpkgs.url = "github:nixos/nixpkgs";
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
    lunar-tools = {
      url = "git+ssh://git@github.com/lunarway/lw-nix?ref=feat/zsh-plugin";
    };
    helix.url = "github:helix-editor/helix";
  };
  outputs =
    inputs@{
      self,
      nixpkgs-unstable, # TODO: inject as option
      nixpkgs,
      darwin,
      home-manager,
      nix-homebrew,
      flake-utils,
      lunar-tools,
      helix,
      ...
    }:
    let
      overlays = [
        lunar-tools.overlays.default
        helix.overlays.default
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
          enableLunarTools = false;
        };

        # "personal-mac" = {
        #   system = "aarch64-darwin";
        #   user = "erik";
        #   nixDirectory = "~/.config/nix-config";
        #   hostModule = ./nix/modules/home-personal.nix;
        #   machineConfig = ./machines/personal-mac.nix;
        #   enableHomebrew = false;
        #   enableLunarTools = false;
        # };

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
              enableLunarTools = config.enableLunarTools;
            })
          ];
        };

    in
    {
      darwinConfigurations = builtins.mapAttrs mkDarwinSystem systemConfigs;
    };
}
