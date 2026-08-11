{ config, lib, ... }:
let
  cfg = config.host.hardware.gpu;
  vendorType = lib.types.enum [
    "amd"
    "intel"
    "nvidia"
  ];
in
{
  imports = [
    ./assertions.nix
    ./amd.nix
    ./collector.nix
    ./intel.nix
    ./rocm.nix
  ];

  options.host.hardware.gpu = {
    vendors = lib.mkOption {
      type = lib.types.listOf vendorType;
      default = [ ];
      apply =
        vendors:
        let
          unsupported = builtins.filter (
            vendor:
            !builtins.elem vendor [
              "amd"
              "intel"
            ]
          ) vendors;
        in
        if unsupported == [ ] then
          vendors
        else
          throw "GPU support is not implemented for: ${lib.concatStringsSep ", " unsupported}";
      description = "GPU vendors supported by this host.";
    };

    render = {
      device = lib.mkOption {
        type = with lib.types; nullOr nonEmptyStr;
        default = null;
        description = "Preferred DRM render device for hardware-accelerated services.";
      };

      vendor = lib.mkOption {
        type = with lib.types; nullOr vendorType;
        default =
          if cfg.render.device != null && builtins.length cfg.vendors == 1 then
            builtins.head cfg.vendors
          else
            null;
        description = "GPU vendor providing the preferred render device.";
      };
    };

    compute = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "rocm" ]);
      default = null;
      description = "GPU compute stack to enable.";
    };

    collector.enable = lib.mkEnableOption "AMD GPU Prometheus textfile collector";
  };
}
