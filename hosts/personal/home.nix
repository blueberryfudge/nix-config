{
  pkgs,
  ...
}:

{
  home.stateVersion = "24.05";
  # TODO: remove?
  programs.home-manager.enable = true;

  home.packages = with pkgs; [
    neofetch
    nerd-fonts.fira-code
    nerd-fonts.fira-mono
  ];

  home.sessionVariables = { };

  ## this are required and shouldn't be disabled
  core-zsh.enable = true;
  core-git.enable = true;
  editor.enable = true;
  starship.enable = true;

  # optional modules
  cli-tooling.enable = true;
  devops-tooling.enable = true;
  # matrix-tooling.enable = true;
  # lang-tooling.enable = true;
}
