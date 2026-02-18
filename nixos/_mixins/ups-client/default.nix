{
  pkgs,
  upsShutdownDelaySeconds,
  isCriticalNode ? false,
  monitorName,
  system,
  user,
  passwordText,
  ...
}:
{
  imports = [
    (import ../ups-sched.nix { inherit pkgs upsShutdownDelaySeconds isCriticalNode; })
  ];

  environment.etc."nut/upsclient.pass" = {
    text = "${passwordText}\n";
    mode = "0600";
  };

  power.ups = {
    enable = true;
    mode = "netclient";
    upsmon.monitor.${monitorName} = {
      inherit system user;
      passwordFile = "/etc/nut/upsclient.pass";
      type = "slave";
    };
  };

  # Netclient mode depends on network reachability to the UPS server.
  systemd.services.upsmon = {
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
  };
}
