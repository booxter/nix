{ config, lib, ... }:
let
  model = import ./model.nix { inherit config lib; };
  inherit (model) cfg;
  storageClaim = config.host.storage.claims.${cfg.storage.claim} or null;
in
{
  config.assertions = lib.optionals (cfg != null) [
    {
      assertion = storageClaim != null;
      message = "host.aurral.storage.claim must name a host storage claim";
    }
    {
      assertion =
        storageClaim != null && cfg.flowDir == "${storageClaim.mountPoint}/${cfg.storage.relativePath}";
      message = "host.aurral.flowDir must match the selected storage claim and relative path";
    }
  ];
}
