{ config, ... }:
let
  vikunjaPort = 3456;
  # Vikunja expects an IANA tz database name here, not a fixed abbreviation.
  vikunjaTimezone = "America/New_York";
in
{
  services.vikunja = {
    enable = true;
    frontendScheme = "http";
    frontendHostname = "${config.services.avahi.hostName}.local:${toString vikunjaPort}";
    port = vikunjaPort;
    settings = {
      defaultsettings = {
        timezone = vikunjaTimezone;
        week_start = 1;
      };
      metrics.enabled = true;
      service.timezone = vikunjaTimezone;
    };
  };

  networking.firewall.allowedTCPPorts = [ vikunjaPort ];
}
