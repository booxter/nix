{
  config,
  lib,
  ...
}:
let
  cfg = config.host.ups.server;
  useLiteralPasswords = config.host.ups.credentialMode == "literal";
  passwordFile =
    user:
    if useLiteralPasswords then
      "/etc/nut/${user}.pass"
    else
      config.sops.secrets."nut/users/${user}/password".path;
in
{
  config = lib.mkIf (cfg != null) {
    host.network.stableAddress.requiredBy = [ "UPS server" ];

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

      ups.${cfg.name} = {
        driver = "usbhid-ups";
        port = "auto";
        description = cfg.description;
      };

      upsd.listen = [
        { address = "0.0.0.0"; }
        { address = "::"; }
      ];

      users = {
        upsmon = {
          passwordFile = passwordFile "upsmon";
          upsmon = "primary";
        };
        upsslave = {
          passwordFile = passwordFile "upsslave";
          upsmon = "secondary";
        };
      };

      upsmon.monitor.local = {
        system = cfg.name;
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
