{ pkgs, ... }: {
  imports = [ 
    ../../modules/darwin 
    ../../modules/shared 
  ];

  system.primaryUser = "x";
  homebrew.enable = true;
}
