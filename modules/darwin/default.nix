{ lib, ... }:

let
  nixFiles = builtins.filter (f: lib.hasSuffix ".nix" f) (lib.filesystem.listFilesRecursive ./.);

  excluded = [
    (toString ./default.nix)
    (toString ./template.nix)
    (toString ./casks.nix)
    (toString ./brews.nix)
  ];

  filtered = builtins.filter (f: !(builtins.elem (toString f) excluded)) nixFiles;
in
{
  imports = map import filtered;
}
