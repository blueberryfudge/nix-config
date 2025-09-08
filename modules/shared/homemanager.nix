{
  user,
  homeModule,
  inputs,
  nixfiles,
  nixDirectory,
  enableHomebrew,
  enableLunarTools,
  gitConfig,
  ...
}:

{
  config,
  pkgs,
  system,
  ...
}:

{
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    backupFileExtension = "bak";

    users = {
      "${user}" = import homeModule;
    };

    sharedModules = [
      ../home
    ];

    extraSpecialArgs = {
      inherit inputs;
      inherit nixfiles;
      inherit nixDirectory;
      inherit enableHomebrew;
      inherit enableLunarTools;
      inherit gitConfig;
    };
  };
}
