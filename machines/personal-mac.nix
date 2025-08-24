{ pkgs, ... }: {
  imports = [ 
    ../modules/base.nix 
    ../modules/homebrew.nix 
  ];

  system.primaryUser = builtins.getEnv "SUDO_USER";
  homebrew.enable = true;
}
