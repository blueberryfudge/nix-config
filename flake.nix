{
  description = "Multi-machine nix-darwin configurations";


  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
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
    lunar-tools.url = "git+ssh://git@github.com/lunarway/lw-nix";
  };
  outputs =
    inputs@{
      self,
      nixpkgs,
      darwin,
      home-manager,
      nix-homebrew,
      flake-utils,
      lunar-tools,
      ...
    }:
    let
      nixfiles = ./.;
      systemConfigs = {
        "work-mac" = {
          system = "aarch64-darwin";
          user = "edb";
          gitName = "edvardxlunar";
          nixDirectory = "~/.config/nix-config";
          hostModule = ./nix/modules/home.nix;
          machineConfig = ./machines/work-mac.nix;
          enableHomebrew = false;
          enableLunarTools = true;
        };

       # "personal-mac" = {
       # system = "aarch64-darwin";
       # user = "erik";
       # gitName = "";
       # nixDirectory = "~/.config/nix-config";
       # hostModule = ./nix/modules/home-personal.nix;
       # machineConfig = ./machines/personal-mac.nix;
       # enableHomebrew = false;
       # enableLunarTools = false;
      #};

      };
      mkDarwinSystem = hostname: config: darwin.lib.darwinSystem {
        system = config.system;
        specialArgs = { 
          inherit inputs nixfiles;
          user = config.user;
        };
        modules = [
          config.machineConfig
          home-manager.darwinModules.home-manager
        ] ++ (if config.enableHomebrew then [nix-homebrew.darwinModules.nix-homebrew] else [])
          ++ [
          (import ./nix/modules/home/homemanager.nix {
            inherit nixfiles;
            user = config.user;
            nixDirectory = config.nixDirectory;
            gitName = config.gitName;
            hostModule = config.hostModule;
            inputs = inputs;
            enableHomebrew = config.enableHomebrew;
            enableLunarTools = config.enableLunarTools;
          })
        ];
      };
  
    in {
      darwinConfigurations = builtins.mapAttrs mkDarwinSystem systemConfigs;
    };
  }
