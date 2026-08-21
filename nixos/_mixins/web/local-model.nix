{ config, lib, ... }:
{
  config._module.args.webModel = import ./model.nix { inherit config lib; };
}
