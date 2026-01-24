{
  pkgs,
  upsShutdownDelaySeconds,
  monitorName,
  system,
  user,
  passwordText,
  ...
}:
let
  shutdownDelaySeconds = upsShutdownDelaySeconds;
in
{
  imports = [
    (import ../ups-sched.nix { inherit pkgs shutdownDelaySeconds; })
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
}
