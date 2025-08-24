{ pkgs, ... }: {
  imports = [ 
    ../modules/base.nix 
    ../modules/homebrew.nix 
  ];

  system.primaryUser = "edb";
  homebrew.enable = false;
}
