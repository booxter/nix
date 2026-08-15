{
  config,
  lib,
  pkgs,
  ...
}:
{
  config = lib.mkIf (config.host.remote-control.server.wayland != null) {
    environment.systemPackages = [ pkgs.waypipe ];
  };
}
