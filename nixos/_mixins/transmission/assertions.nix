{ config, lib, ... }:
let
  model = import ./model.nix { inherit config; };
  inherit (model) cfg;
in
{
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = model.vpnNamespace != null;
        message = "host.transmission.vpn.namespace must select a known VPN namespace";
      }
      {
        assertion =
          cfg.trackerPolicy.nonPreferred.lowPriorityRatio < cfg.trackerPolicy.nonPreferred.pauseRatio;
        message = "host.transmission tracker low-priority ratio must be below its pause ratio";
      }
      {
        assertion = !cfg.torrentCleaner.enable || cfg.trackerPolicy.enable;
        message = "host.transmission.torrentCleaner requires trackerPolicy";
      }
      {
        assertion = cfg.torrentCleaner.maximumAgeDays >= cfg.torrentCleaner.minimumAgeDays;
        message = "host.transmission cleaner maximum age must not be below its minimum age";
      }
    ];
  };
}
