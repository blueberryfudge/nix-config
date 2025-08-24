{ pkgs, ... }:
let
  local = import ../local.nix;
in {
  imports = [ 
    ../modules/base.nix 
    ../modules/homebrew.nix 
  ];

  system.primaryUser = local.primaryUser;
  homebrew.enable = false;
}
