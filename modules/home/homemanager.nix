{
  user,
  hostModule,
  inputs,
  nixfiles,
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
    };
  };
}
