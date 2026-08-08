{
  config,
  lib,
  ...
}:
let
  cfg = config.services.jellarr;
  acceleration = config.host.videoAcceleration;
in
{
  options.services.jellarr.useHostVideoAcceleration = lib.mkEnableOption "Jellarr configuration derived from host video acceleration";

  config = lib.mkIf cfg.useHostVideoAcceleration {
    assertions = [
      {
        assertion = acceleration != null;
        message = "services.jellarr.useHostVideoAcceleration requires host.videoAcceleration.";
      }
    ];

    services.jellarr.config.encoding = {
      hardwareAccelerationType = acceleration.backend;
      qsvDevice = acceleration.device;
    };
  };
}
