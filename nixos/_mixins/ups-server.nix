{
  config,
  hostInventory,
  lib,
  ...
}:
let
  cfg = config.host.ups;
  credentialMode = hostInventory.realms.${config.host.realm}.services.ups.credentialMode;
  useLiteralPasswords = credentialMode == "literal";
  upsName = hostInventory.toUpsName config.networking.hostName;
  upsmonPasswordText = if useLiteralPasswords then "upsmon123" else null;
  upsslavePasswordText = if useLiteralPasswords then "upsslave123" else null;
  upsmonPasswordFile =
    if upsmonPasswordText == null then
      config.sops.secrets."nut/users/upsmon/password".path
    else
      "/etc/nut/upsmon.pass";
  upsslavePasswordFile =
    if upsslavePasswordText == null then
      config.sops.secrets."nut/users/upsslave/password".path
    else
      "/etc/nut/upsslave.pass";
in
{
  config = lib.mkIf cfg.server.enable {
    host.ups.scheduler = {
      enable = true;
      inherit (cfg.shutdown) critical;
      shutdownDelaySeconds = cfg.shutdown.delaySeconds;
    };

    environment.etc."nut/upsmon.pass" = lib.mkIf useLiteralPasswords {
      text = "${upsmonPasswordText}\n";
      mode = "0600";
    };
    environment.etc."nut/upsslave.pass" = lib.mkIf useLiteralPasswords {
      text = "${upsslavePasswordText}\n";
      mode = "0600";
    };

    sops.secrets = lib.mkIf (!useLiteralPasswords) {
      "nut/users/upsmon/password" = {
        mode = "0400";
        restartUnits = [
          "upsd.service"
          "upsmon.service"
        ];
      };
      "nut/users/upsslave/password" = {
        mode = "0400";
        restartUnits = [ "upsd.service" ];
      };
    };

    power.ups = {
      enable = true;
      mode = "netserver";
      openFirewall = true;

      ups.${upsName} = {
        driver = "usbhid-ups";
        port = "auto";
        description = cfg.server.description;
      };

      upsd.listen = [
        { address = "0.0.0.0"; }
        { address = "::"; }
      ];

      users = {
        upsmon = {
          passwordFile = upsmonPasswordFile;
          upsmon = "primary";
        };
        upsslave = {
          passwordFile = upsslavePasswordFile;
          upsmon = "secondary";
        };
      };

      upsmon.monitor.local = {
        system = upsName;
        user = "upsmon";
        type = "master";
      };
    };

    systemd.services = lib.mkIf (!useLiteralPasswords) {
      upsd = {
        wants = [ "sops-install-secrets.service" ];
        after = [ "sops-install-secrets.service" ];
      };
      upsmon = {
        wants = [ "sops-install-secrets.service" ];
        after = [ "sops-install-secrets.service" ];
      };
    };
  };
}
