{
  lib,
  transmissionModel,
  ...
}:
let
  model = transmissionModel;
  inherit (model) cfg;
in
{
  config = lib.mkIf (cfg != null) {
    assertions = [
      {
        assertion = model.vpnNamespace != null;
        message = "host.transmission requires the 'wg' VPN namespace";
      }
      {
        assertion = cfg.torrentCleaner == null || cfg.trackerPolicy != null;
        message = "host.transmission.torrentCleaner requires trackerPolicy";
      }
    ];
  };
}
