{
  config,
  lib,
  options,
  outputs ? {
    nixosConfigurations = { };
  },
  pkgs,
  utils,
  ...
}:
let
  hasHostTransmission = options.host.transmission.uploadLimit or null != null;
  runtime = import ../runtime.nix {
    inherit
      config
      lib
      outputs
      pkgs
      utils
      ;
  };
  inherit (runtime)
    cfg
    command
    commonServiceConfig
    deciderUnit
    ;
in
{
  config = lib.mkMerge [
    (lib.mkIf (cfg.enable && cfg.outputs.transmission.enable) {
      systemd.services.adaptive-upload-policy-transmission = {
        description = "Apply adaptive upload policy to Transmission";
        wantedBy = [ "multi-user.target" ];
        wants = [
          "network-online.target"
          deciderUnit
        ]
        ++ lib.optional cfg.outputs.transmission.local "transmission.service";
        after = [
          "network-online.target"
          deciderUnit
        ]
        ++ lib.optional cfg.outputs.transmission.local "transmission.service";
        serviceConfig = commonServiceConfig // {
          ExecStart = command "apply-transmission";
          RestrictAddressFamilies = [
            "AF_UNIX"
            "AF_INET"
            "AF_INET6"
          ];
        };
      };
    })
    (lib.optionalAttrs hasHostTransmission {
      host.transmission.uploadLimit =
        lib.mkIf (cfg.enable && cfg.outputs.transmission.enable && cfg.outputs.transmission.local)
          {
            enable = true;
            # Start at the safe fallback before the runtime controller has produced
            # its first policy decision.
            initialKBytesPerSecond = lib.mkDefault (
              builtins.floor (
                (cfg.fallbackRateMbit * 1000.0 / 8.0) * (cfg.outputs.transmission.headroomPercent / 100.0)
              )
            );
          };
    })
  ];
}
