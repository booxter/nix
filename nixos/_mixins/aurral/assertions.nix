{ config, lib, ... }:
let
  model = import ./model.nix { inherit config lib; };
  inherit (model) cfg;
in
{
  config.assertions = lib.optionals (cfg != null) [
    {
      assertion = model.storageClaim != null;
      message = "host.aurral.storageClaim must name a host storage claim";
    }
  ];
}
