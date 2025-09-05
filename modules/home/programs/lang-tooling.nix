{
  pkgs,
  lib,
  config,
  ...
}:

{
  options = {
    lang-tooling.enable = lib.mkEnableOption "enables lang-tooling";
  };

  config = lib.mkIf config.lang-tooling.enable {
    # preferrably install language tooling directly with nix
    home.packages = with pkgs; [
      rustup
      devenv
    ];

    # if required can use mise as a fallback (sometimes easier)
    programs.mise = {
      enable = true;
      enableZshIntegration = true;
      globalConfig = {
        settings = {
          pipx_uvx = true;
          idiomatic_version_file_enable_tools = [ ];
        };

        tools = {
          uv = "0.7";
          python = "3.13";
        };
      };
    };
  };
}
