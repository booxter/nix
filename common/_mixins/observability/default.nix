{ config, lib, ... }:
{
  imports = [ ./node-exporter.nix ];

  options.host.observability.enable = lib.mkEnableOption "host-side observability services";

  config.host.observability.enable = lib.mkDefault (!config.host.isWork);
}
