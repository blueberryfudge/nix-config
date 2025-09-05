{ pkgs, ... }: {
  imports = [ 
    ../modules/darwin.nix 
    ../modules/darwin
    ../modules/shared
  ];

}
