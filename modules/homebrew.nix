{ pkgs, lib, config, ... }: {
  homebrew = {
    
    brews = [
      # CLI tools via homebrew
    ];

    casks = [
      "ghostty"
      "font-jetbrains-mono-nerd-font"
    ];
    
    masApps = {
      # "Xcode" = 497799835;
    };
    
    taps = [
      # Custom taps if needed
    ];
    
    onActivation = {
      cleanup = "none";
      autoUpdate = true;
      upgrade = true;
    };
  };
}
