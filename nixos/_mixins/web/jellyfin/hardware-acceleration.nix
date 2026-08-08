{
  config,
  lib,
  ...
}:
let
  cfg = config.services.jellyfin;
  acceleration = if config.host.gpu == null then null else config.host.gpu.videoAcceleration;
in
{
  options.services.jellyfin.useHostVideoAcceleration = lib.mkEnableOption "hardware video acceleration declared by the host";

  config = lib.mkIf cfg.useHostVideoAcceleration {
    assertions = [
      {
        assertion = acceleration != null;
        message = "services.jellyfin.useHostVideoAcceleration requires host.gpu.videoAcceleration.";
      }
    ];

    services = {
      jellyfin.supplementaryGroups = [
        "render"
        "video"
      ];

      jellarr.config.encoding = lib.mkIf config.services.jellarr.enable {
        hardwareAccelerationType = acceleration.backend;
        qsvDevice = acceleration.device;
      };
    };
  };
}
