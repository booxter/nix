{ lib, ... }:
{
  imports = [
    ./amd.nix
    ./collector.nix
    ./intel.nix
    ./rocm.nix
  ];

  options.host.hardware.gpu = {
    vendors = lib.mkOption {
      type = lib.types.listOf (
        lib.types.enum [
          "amd"
          "intel"
          "nvidia"
        ]
      );
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
