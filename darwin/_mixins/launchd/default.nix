{
  config,
  inputs,
  lib,
  ...
}:
let
  launchdModel = import ./model.nix { inherit config lib; };
in
{
  disabledModules = [ "system/launchd.nix" ];
  imports = [
    (inputs.nix-darwin-launchd + "/modules/system/launchd.nix")
    ./assertions.nix
    ./certificates.nix
    ./logging.nix
    ./observability.nix
  ];

  _module.args = { inherit launchdModel; };
}
