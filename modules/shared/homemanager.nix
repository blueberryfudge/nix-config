{
  user,
  homeModule,
  inputs,
  nixfiles,
  nixDirectory,
  enableHomebrew ? true,
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
      inherit user;
      inherit gitConfig;
    };
  };
}
