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
    qosService
    ;
in
{
  config.systemd.services.adaptive-upload-policy-qos =
    lib.mkIf (cfg.enable && cfg.outputs.qos.enable)
      {
        description = "Apply adaptive upload policy to a host.qos limit";
        wantedBy = [ "multi-user.target" ];
        wants = [
          deciderUnit
          qosService
        ];
        after = [
          deciderUnit
          qosService
        ];
        partOf = [ qosService ];
        serviceConfig = commonServiceConfig // {
          ExecStart = command "apply-qos";
          AmbientCapabilities = [ "CAP_NET_ADMIN" ];
          CapabilityBoundingSet = [ "CAP_NET_ADMIN" ];
          RestrictAddressFamilies = [
            "AF_UNIX"
            "AF_NETLINK"
          ];
        };
      };
}
