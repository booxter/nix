{
  config,
  lib,
  storageModel,
  ...
}:
{
  imports = [
    ./account.nix
    ./assertions.nix
    ./downloads.nix
    ./metrics.nix
    ./options.nix
    ./secrets.nix
    ./service.nix
    ./storage.nix
    ./vpn.nix
    ./web.nix
  ];

  config._module.args.sabnzbdModel = import ./model.nix { inherit config lib storageModel; };
}
