{
  description = "Work machine nix-darwin configuration";

  inputs = {
    personal-config.url = "path:..";
    lunar-tools = {
      url = "git+ssh://git@github.com/lunarway/lw-nix";
    };
  };

  outputs = { personal-config, lunar-tools, ... }:
  let
    inherit (personal-config.lib) mkSystem;
  in
  {
    darwinConfigurations.work-mac = mkSystem {
      user = "edb";
      homeModule = ../hosts/work/home.nix;
      hostModule = ../hosts/work;
      enableHomeBrew = true;
      extraOverlays = [ lunar-tools.overlays.default];
      gitConfig = {
        userName = "Edvard Boguslavskij";
        userEmail = "edb@lunar.app";
        signingKey = "/Users/edb/.ssh/github.pub";
        workSSHKey = "/Users/edb/.ssh/github";
        personalSSHKey = "/Users/edb/.ssh/id_ed25519";
        enableLunarUrls = true;
        enablePersonalAlias = true;
        user = "edb";
      };
    };
  };
}
