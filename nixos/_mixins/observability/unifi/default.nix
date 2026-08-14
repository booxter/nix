{ config, lib, ... }:
let
  cfg = config.host.observability.unifi;
  controller = config.host.site.lan.ipController;
in
{
  imports = [ ./service.nix ];

  options.host.observability.unifi.enable = lib.mkEnableOption "UniFi network observability";

  config.assertions = lib.optionals cfg.enable [
    {
      assertion = controller != null;
      message = "host.observability.unifi requires an IP controller for this physical site";
    }
    {
      assertion = controller != null && controller.flavor == "unifi";
      message = "host.observability.unifi requires a UniFi site network controller";
    }
  ];
}
