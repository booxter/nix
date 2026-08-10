{
  config,
  ...
}:
let
  cfg = config.host.ups;
in
{
  config.assertions = [
    {
      assertion = !cfg.server.enable || cfg.server.description != null;
      message = "host.ups.server.description is required when the UPS server is enabled";
    }
    {
      assertion = !cfg.shutdown.critical || cfg.server.enable;
      message = "only a UPS server may wait for a low-battery event";
    }
  ];
}
