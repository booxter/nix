{ lib, ... }:
{
  imports = [ ./vnc.nix ];

  options.host.remote-control.server.vnc = lib.mkOption {
    type = lib.types.nullOr (lib.types.submodule { });
    default = null;
  };
}
