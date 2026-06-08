{
  pkgs,
  upsName,
  upsDescription,
  upsShutdownDelaySeconds ? 600,
  isCriticalNode ? false,
  upsmonPasswordText ? null,
  upsslavePasswordText ? null,
  ...
}:
{ config, lib, ... }:
let
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
  imports = [
    (import ./ups-sched.nix { inherit pkgs upsShutdownDelaySeconds isCriticalNode; })
  ];

  environment.etc."nut/upsmon.pass" = lib.mkIf (upsmonPasswordText != null) {
    text = "${upsmonPasswordText}\n";
    mode = "0600";
  };
  environment.etc."nut/upsslave.pass" = lib.mkIf (upsslavePasswordText != null) {
    text = "${upsslavePasswordText}\n";
    mode = "0600";
  };

  sops.secrets = lib.mkMerge [
    (lib.mkIf (upsmonPasswordText == null) {
      "nut/users/upsmon/password" = {
        mode = "0400";
        restartUnits = [
          "upsd.service"
          "upsmon.service"
        ];
      };
    })
    (lib.mkIf (upsslavePasswordText == null) {
      "nut/users/upsslave/password" = {
        mode = "0400";
        restartUnits = [ "upsd.service" ];
      };
    })
  ];

  power.ups = {
    enable = true;
    mode = "netserver";
    openFirewall = true;

    ups.${upsName} = {
      driver = "usbhid-ups";
      port = "auto";
      description = upsDescription;
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

  systemd.services = lib.mkIf (upsmonPasswordText == null || upsslavePasswordText == null) {
    upsd = {
      wants = [ "sops-install-secrets.service" ];
      after = [ "sops-install-secrets.service" ];
    };
    upsmon = {
      wants = [ "sops-install-secrets.service" ];
      after = [ "sops-install-secrets.service" ];
    };
  };
}
