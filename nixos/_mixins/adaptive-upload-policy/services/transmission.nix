{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  runtime = import ../runtime.nix {
    inherit
      config
      lib
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
  config = lib.mkIf (cfg.enable && cfg.outputs.transmission.enable) {
    host.transmission.uploadLimit = {
      enable = true;
      # Start at the safe fallback before the runtime controller has produced
      # its first policy decision.
      initialKBytesPerSecond = lib.mkDefault (
        builtins.floor (
          (cfg.fallbackRateMbit * 1000.0 / 8.0) * (cfg.outputs.transmission.headroomPercent / 100.0)
        )
      );
    };

    systemd.services.adaptive-upload-policy-transmission = {
      description = "Apply adaptive upload policy to Transmission";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "network-online.target"
        deciderUnit
        "transmission.service"
      ];
      after = [
        "network-online.target"
        deciderUnit
        "transmission.service"
      ];
      serviceConfig = commonServiceConfig // {
        ExecStart = command "apply-transmission";
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
      };
    };
  };
}
