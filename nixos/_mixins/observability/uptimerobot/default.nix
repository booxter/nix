{ lib, ... }:
{
  imports = [
    ./controller.nix
  ];

  options.host.observability.uptimeRobot.controller.enable =
    lib.mkEnableOption "authoritative UptimeRobot monitor reconciliation";
}
