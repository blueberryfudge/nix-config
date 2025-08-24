{ pkgs, ... }: {
  imports = [ 
    ../modules/base.nix 
    ../modules/homebrew.nix 
  ];

  system.primaryUser = "x";
  homebrew.enable = true;
}
