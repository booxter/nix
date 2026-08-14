{ lib, ... }:
{
  imports = [ ./service.nix ];

  options.host.observability.unifi.enable = lib.mkEnableOption "UniFi network observability";
}
