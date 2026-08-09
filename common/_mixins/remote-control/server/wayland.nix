{
  config,
  lib,
  pkgs,
  ...
}:
{
  config = lib.mkIf config.remote-control.server.wayland.enable {
    environment.systemPackages = [ pkgs.waypipe ];
  };
}
