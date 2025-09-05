{
  user,
  hostModule,
  inputs,
  nixfiles,
  nixDirectory,
  enableHomebrew,
  enableLunarTools,
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

    users = {
      "${user}" = import hostModule;
    };

    sharedModules = [
      ./.
    ];

    extraSpecialArgs = {
      inherit inputs;
      inherit nixfiles;
      inherit nixDirectory;
      inherit enableHomebrew;
      inherit enableLunarTools;
    };
  };
}
