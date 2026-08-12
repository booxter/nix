{ config, lib, ... }:
let
  model = import ./model.nix { inherit config lib; };
  inherit (model) cfg selected;
  storageClaim = config.host.storage.claims.${cfg.storage.claim} or null;
in
{
  config.assertions =
    lib.optionals cfg.enable [
      {
        assertion = storageClaim != null;
        message = "host.aurral.storage.claim must name a host storage claim";
      }
      {
        assertion =
          storageClaim != null && cfg.flowDir == "${storageClaim.mountPoint}/${cfg.storage.relativePath}";
        message = "host.aurral.flowDir must match the selected storage claim and relative path";
      }
    ]
    ++ lib.optionals cfg.slskd.enable [
      {
        assertion = cfg.enable;
        message = "host.aurral.slskd.enable requires host.aurral.enable";
      }
      {
        assertion = cfg.slskd.instance != null;
        message = "host.aurral.slskd.instance must select a host-local slskd instance";
      }
      {
        assertion = selected != null;
        message = "host.aurral.slskd.instance must name an enabled host.slskd.instances entry";
      }
    ];
}
