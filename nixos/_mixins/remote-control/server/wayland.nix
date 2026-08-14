{
  config,
  lib,
  pkgs,
  ...
}:
{
  config = lib.mkIf config.host.remote-control.server.wayland.enable {
    environment.systemPackages = [ pkgs.waypipe ];
  };
}
