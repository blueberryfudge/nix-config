{ pkgs, ... }: {
  imports = [ 
    ../modules/darwin.nix 
    ../modules/homebrew.nix 
    ../modules/darwin
    ../modules/shared
  ];
  core-git.enable = true;
  core-zsh.enable = true;

  # optional modules
  cli-tooling.enable = true;
  devops-tooling.enable = true;
  data.enable = true;
  lang-tooling.enable = true;

}
