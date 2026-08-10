{ config, ... }:
let
  cfg = config.host.jellyfin;
in
{
  assertions = [
    {
      assertion = !cfg.enable || cfg.media.source != null;
      message = "host.jellyfin.media.source must be set when Jellyfin is enabled.";
    }
    {
      assertion = !cfg.enable || !cfg.backups.enable || cfg.backups.stagingDirectory != null;
      message = "host.jellyfin.backups.stagingDirectory must be set when Jellyfin backups are enabled.";
    }
    {
      assertion = !cfg.enable || cfg.web.transport != "direct" || config.host.web.ingress.enable;
      message = "host.jellyfin.web.transport `direct` requires this host to run realm ingress.";
    }
  ];
}
