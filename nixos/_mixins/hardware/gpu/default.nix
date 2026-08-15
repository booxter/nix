{ lib, ... }:
let
  vendorType = lib.types.enum [
    "amd"
    "intel"
  ];
in
{
  imports = [
    ./amd.nix
    ./collector.nix
    ./intel.nix
    ./rocm.nix
  ];

  options.host.hardware.gpu = {
    vendor = lib.mkOption {
      type = lib.types.nullOr vendorType;
      default = null;
      description = "GPU vendor supported by this host.";
    };

    renderDevice = lib.mkOption {
      type = with lib.types; nullOr nonEmptyStr;
      default = null;
      description = "Preferred DRM render device for hardware-accelerated services.";
    };

    compute = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "rocm" ]);
      default = null;
      description = "GPU compute stack to enable.";
    };

    collector.enable = lib.mkEnableOption "AMD GPU Prometheus textfile collector";
  };
}
