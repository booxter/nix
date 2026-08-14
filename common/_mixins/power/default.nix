{
  config,
  lib,
  ...
}:
let
  cfg = config.host.power.shutdown;
  participates = config.host.ups.server != null || config.host.ups.client.server != null;
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
