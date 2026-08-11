{ config, ... }:
let
  cfg = config.host.hardware.gpu;
in
{
  assertions = [
    {
      assertion = (cfg.render.device == null) == (cfg.render.vendor == null);
      message = "host.hardware.gpu.render.device and vendor must be configured together";
    }
    {
      assertion = cfg.render.vendor == null || builtins.elem cfg.render.vendor cfg.vendors;
      message = "host.hardware.gpu.render.vendor must be listed in host.hardware.gpu.vendors";
    }
  ];
}
