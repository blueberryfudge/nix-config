{ pkgs, ... }: {
  imports = [ 
    ../modules/base.nix 
    ../modules/homebrew.nix 
  ];

  system.primaryUser = builtins.getEnv "USER";
  homebrew.enable = true;
}
