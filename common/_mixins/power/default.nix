{
  config,
  fleetInventory,
  lib,
  ...
}:
let
  cfg = config.host.power.shutdown;
  hostName = config.networking.hostName;
  participates =
    builtins.hasAttr hostName fleetInventory.ups.servers
    || builtins.hasAttr hostName fleetInventory.ups.clients;
in
{
  options.host.power.shutdown = {
    leadSeconds = lib.mkOption {
      type = with lib.types; attrsOf ints.positive;
      default = { };
      internal = true;
      description = "Shutdown lead-time contributions subtracted from the UPS base delay.";
    };

    delaySeconds = lib.mkOption {
      type = with lib.types; nullOr ints.positive;
      default =
        if participates then
          900 - lib.foldl' builtins.add 0 (builtins.attrValues cfg.leadSeconds)
        else
          null;
      readOnly = true;
      internal = true;
      description = "Derived delay after an on-battery event before shutdown.";
    };
  };
}
