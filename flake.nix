{
  description = "Multi-machine nix-darwin configurations";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nix-darwin.url = "github:nix-darwin/nix-darwin/master";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs@{ self, nix-darwin, nixpkgs }: {
    darwinConfigurations = {
      "work-mac" = nix-darwin.lib.darwinSystem {
        modules = [ ./machines/work-mac.nix];
      };
    };
  };
}
