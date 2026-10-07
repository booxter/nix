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
    ./auth.nix
    ./backups.nix
    ./cache.nix
    ./database.nix
    ./options.nix
    ./secrets.nix
    ./service.nix
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
