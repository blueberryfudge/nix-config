{
  pkgs,
  ...
}:

{
  home.stateVersion = "24.05";
  programs.home-manager.enable = true;

  home.packages = with pkgs; [
    neofetch
    nerd-fonts.fira-code
    nerd-fonts.fira-mono
  ];

  home.sessionVariables = {
    LANG = "en_US.UTF-8";
    LC_ALL = "";
  };

}
