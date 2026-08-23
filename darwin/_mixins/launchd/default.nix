{ config, lib, ... }:
let
  launchdModel = import ./model.nix { inherit config lib; };
in
{
  imports = [
    ./assertions.nix
    ./logging.nix
    ./observability.nix
  ];

  _module.args = { inherit launchdModel; };
}
