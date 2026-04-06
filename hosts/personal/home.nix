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
    monaspace
    nerd-fonts.jetbrains-mono
    nerd-fonts.symbols-only
  ];

  home.sessionVariables = { };

  ## this are required and shouldn't be disabled
  core-zsh.enable = true;
  core-git.enable = true;
  core-zsh.enableLunar = false;
  editor.enable = true;
  ghostty.enable = true;
  ghostty.fontFamily = "JetBrainsMono Nerd Font Mono";
  ghostty.fontThicken = false;
  zellij.enable = true;
  starship.enable = true;

  # optional modules
  ai-agents.enable = true;
  cli-tooling.enable = true;
  devops-tooling.enable = true;
  # matrix-tooling.enable = true;
  # lang-tooling.enable = true;
}
