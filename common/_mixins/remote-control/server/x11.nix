{
  config,
  lib,
  ...
}:
{
  config = lib.mkIf config.host.remote-control.server.x11.enable {
    services.openssh.settings.X11Forwarding = true;
  };
}
