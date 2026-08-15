{
  config,
  lib,
  pkgs,
  storageModel,
  ...
}:
{
  imports = [
    ./account.nix
    ./assertions.nix
    ./assets.nix
    ./auth.nix
    ./backups.nix
    ./cache.nix
    ./containers.nix
    ./database.nix
    ./options.nix
    ./secrets.nix
    ./setup.nix
    ./storage.nix
    ./web.nix
  ];

  config._module.args.rommModel = import ./model.nix {
    inherit
      config
      lib
      pkgs
      storageModel
      ;
  };
}
