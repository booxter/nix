{
  config,
  hostSpec,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.videoAcceleration;
in
{
  options.host.videoAcceleration = lib.mkOption {
    type = lib.types.nullOr (
      lib.types.submodule {
        options = {
          backend = lib.mkOption {
            type = lib.types.enum [ "qsv" ];
            description = "Hardware video acceleration backend.";
          };
          device = lib.mkOption {
            type = lib.types.str;
            description = "Render device used for hardware video acceleration.";
          };
        };
      }
    );
    default = hostSpec.hardware.videoAcceleration or null;
    readOnly = true;
    internal = true;
    description = "Hardware video acceleration capability declared by inventory.";
  };

  config = lib.mkIf (cfg != null) {
    environment.systemPackages = lib.optionals (cfg.backend == "qsv") (
      with pkgs;
      [
        intel-gpu-tools
        libva-utils
      ]
    );

    hardware.graphics = {
      enable = true;
      extraPackages = lib.optionals (cfg.backend == "qsv") (
        with pkgs;
        [
          intel-media-driver
          intel-compute-runtime
          vpl-gpu-rt
        ]
      );
    };
  };
}
