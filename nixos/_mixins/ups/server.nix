{
  config,
  hostInventory,
  hostSpec,
  lib,
  ...
}:
let
  device = hostInventory.ups.devices.${hostSpec.name} or null;
  credentialMode = hostInventory.realms.${config.host.realm}.services.ups.credentialMode;
  useLiteralPasswords = credentialMode == "literal";
  upsName = hostInventory.toUpsName hostSpec.name;
  upsmonPasswordFile =
    if useLiteralPasswords then
      "/etc/nut/upsmon.pass"
    else
      config.sops.secrets."nut/users/upsmon/password".path;
  upsslavePasswordFile =
    if useLiteralPasswords then
      "/etc/nut/upsslave.pass"
    else
      config.sops.secrets."nut/users/upsslave/password".path;
in
{
  config = lib.mkIf (device != null) {
    host.ups.scheduler.enable = true;

    environment.etc = lib.mkIf useLiteralPasswords {
      "nut/upsmon.pass" = {
        text = "upsmon123\n";
        mode = "0600";
      };
      "nut/upsslave.pass" = {
        text = "upsslave123\n";
        mode = "0600";
      };
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

      ups.${upsName} = device;

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
