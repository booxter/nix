{
  config,
  lib,
  outputs,
  pkgs,
  ...
}:
let
  degoogModel = import ./model.nix {
    inherit
      config
      lib
      outputs
      pkgs
      ;
  };
in
{
  imports = [
    ./assertions.nix
    ./backups.nix
    ./options.nix
    ./secrets.nix
    ./service.nix
    ./web.nix
  ];

  _module.args = { inherit degoogModel; };
}
