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
        message = "host.transmission.vpn.namespace must select a known VPN namespace";
      }
      {
        assertion =
          cfg.trackerPolicy == null
          || cfg.trackerPolicy.nonPreferred.lowPriorityRatio < cfg.trackerPolicy.nonPreferred.pauseRatio;
        message = "host.transmission tracker low-priority ratio must be below its pause ratio";
      }
      {
        assertion = cfg.torrentCleaner == null || cfg.trackerPolicy != null;
        message = "host.transmission.torrentCleaner requires trackerPolicy";
      }
      {
        assertion =
          cfg.torrentCleaner == null
          || cfg.torrentCleaner.maximumAgeDays >= cfg.torrentCleaner.minimumAgeDays;
        message = "host.transmission cleaner maximum age must not be below its minimum age";
      }
    ];
  };
}
