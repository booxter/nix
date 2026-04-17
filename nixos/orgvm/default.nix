{ config, ... }:
let
  vikunjaPort = 3456;
  # Vikunja expects an IANA tz database name here, not a fixed abbreviation.
  vikunjaTimezone = "America/New_York";
in
{
  imports = [
    ./backup.nix
  ];

  sops.defaultSopsFile = ../../secrets/prox-orgvm.yaml;

  sops.secrets.vikunjaMailerPassword = {
    key = "vikunja/mailer/password";
    restartUnits = [ "vikunja.service" ];
  };

  sops.templates."vikunja-mailer.env" = {
    content = ''
      VIKUNJA_MAILER_PASSWORD=${config.sops.placeholder.vikunjaMailerPassword}
    '';
    restartUnits = [ "vikunja.service" ];
  };

  services.vikunja = {
    enable = true;
    environmentFiles = [ config.sops.templates."vikunja-mailer.env".path ];
    frontendScheme = "https";
    frontendHostname = "vi.ihar.dev";
    port = vikunjaPort;
    settings = {
      defaultsettings = {
        timezone = vikunjaTimezone;
        week_start = 1;
      };
      metrics.enabled = true;
      mailer = {
        enabled = true;
        host = "smtp.gmail.com";
        port = 587;
        username = "ihar.hrachyshka@gmail.com";
        fromemail = "ihar.hrachyshka@gmail.com";
      };
      service = {
        timezone = vikunjaTimezone;
        enableregistration = false;
      };
    };
  };

  networking.firewall.allowedTCPPorts = [ vikunjaPort ];
}
