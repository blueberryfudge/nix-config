{ pkgs, lib, config, ... }: {
  homebrew = lib.mkIf config.homebrew.enable {
    enable = true;

    brews = [
      
    ];
    casks = [
      
    ];

    onActivation = {
      cleanup = "none";
      autoUpdate = true;
      upgrade = true;
    };
  };
}
