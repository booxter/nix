{
  config,
  lib,
  ...
}:
let
  cfg = config.host.network;
  hostName = config.networking.hostName;
in
{
  config.assertions = [
    {
      assertion = cfg.stableAddress.requiredBy == [ ] || cfg.reservation != null;
      message = "${hostName} requires a stable site address for: ${lib.concatStringsSep ", " (lib.unique cfg.stableAddress.requiredBy)}";
    }
    {
      assertion = cfg.reservation == null || cfg.stableAddress.requiredBy != [ ];
      message = "${hostName} declares a site IP reservation without a stable-address requirement";
    }
  ];
}
