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
  config.systemd.services.adaptive-upload-policy-transmission =
    lib.mkIf (cfg.enable && cfg.outputs.transmission.enable)
      {
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
}
