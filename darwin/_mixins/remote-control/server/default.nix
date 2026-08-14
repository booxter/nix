{ lib, ... }:
{
  imports = [ ./vnc.nix ];

  options.host.remote-control.server.vnc.enable =
    lib.mkEnableOption "VNC remote-control server functionality";
}
