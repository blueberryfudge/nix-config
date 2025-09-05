{ pkgs, ...}: {
  environment.systemPackages = (import ../shared/packages.nix { inherit pkgs; });

  nix.settings.experimental-features = "nix-command flakes";

  system.configurationRevision = null;
  system.stateVersion = 6;
  nixpkgs.hostPlatform = "aarch64-darwin";

  security = {
    pam.services.sudo_local = {
      enable = true;
      reattach = true;
      touchIdAuth = true;
      watchIdAuth = true;
    };

    sudo = {
      extraConfig = ''
        Defaults timestamp_timeout=5
      '';
    };
  };

  programs.zsh = {
    enable = true;
    enableCompletion = false;
  };
}
