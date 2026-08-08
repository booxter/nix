{
  config,
  lib,
  pkgs,
  ...
}:
let
  server = config.host.remoteGui.server;
in
{
  imports = [ ./reframe.nix ];

  services.openssh.settings.X11Forwarding = lib.mkIf server.x11.enable true;
  environment.systemPackages = lib.optional server.wayland.enable pkgs.waypipe;
}
