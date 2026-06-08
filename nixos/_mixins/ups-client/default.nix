{
  pkgs,
  upsShutdownDelaySeconds,
  isCriticalNode ? false,
  monitorName,
  system,
  user,
  passwordText ? null,
  ...
}:
{ config, lib, ... }:
let
  passwordFile =
    if passwordText == null then
      config.sops.secrets."nut/monitors/${monitorName}/password".path
    else
      "/etc/nut/upsclient.pass";
in
{
  imports = [
    (import ../ups-sched.nix { inherit pkgs upsShutdownDelaySeconds isCriticalNode; })
  ];

  environment.etc."nut/upsclient.pass" = lib.mkIf (passwordText != null) {
    text = "${passwordText}\n";
    mode = "0600";
  };

  sops.secrets = lib.mkIf (passwordText == null) {
    "nut/monitors/${monitorName}/password" = {
      mode = "0400";
      restartUnits = [ "upsmon.service" ];
    };
  };

  power.ups = {
    enable = true;
    mode = "netclient";
    upsmon.monitor.${monitorName} = {
      inherit system user;
      inherit passwordFile;
      type = "slave";
    };
  };

  # Netclient mode depends on network reachability to the UPS server.
  systemd.services.upsmon = {
    wants = [
      "network-online.target"
    ]
    ++ lib.optional (passwordText == null) "sops-install-secrets.service";
    after = [
      "network-online.target"
    ]
    ++ lib.optional (passwordText == null) "sops-install-secrets.service";
  };
}
