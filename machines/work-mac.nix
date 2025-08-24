{ pkgs, ... }: {
  imports = [ 
    ../modules/base.nix 
    ../modules/homebrew.nix 
  ];

  system.primaryUser = "";
  homebrew.enable = false;
}
