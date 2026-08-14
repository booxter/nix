{ config, lib, ... }:
let
  model = import ./model.nix { inherit config lib; };
in
{
  config = lib.mkIf (model.services != { }) {
    host.internalHttps.localAliases = lib.unique (
      builtins.concatMap (service: service.localAliases) (builtins.attrValues model.services)
    );
  };
}
