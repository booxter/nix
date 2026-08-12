{ config, lib, ... }:
let
  cfg = config.host.observability.unifi;
  controller = config.host.network.ipController.resolved;
in
{
  config.assertions = lib.optionals cfg.enable [
    {
      assertion = controller != null;
      message = "host.observability.unifi requires an IP controller for this physical site";
    }
    {
      assertion = controller != null && controller.flavor == "unifi";
      message = "host.observability.unifi requires a UniFi site network controller";
    }
    {
      assertion = controller != null && controller.target.endpoint != null;
      message = "host.observability.unifi requires the site network-controller endpoint";
    }
    {
      assertion = controller != null && controller.target.site != null;
      message = "host.observability.unifi requires the controller-local site identifier";
    }
  ];
}
