{
  config,
  lib,
  outputs ? {
    nixosConfigurations = { };
  },
  pkgs,
  utils,
  ...
}:
let
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
    qosOutput
    qosService
    ;
in
{
  config = lib.mkIf (cfg != null && qosOutput != null) {
    # Start the selected limit at the safe fallback before the runtime
    # controller has produced its first policy decision.
    host.qos.interfaces.${qosOutput.profile}.limits.${qosOutput.limit}.rateMbit =
      lib.mkDefault cfg.fallbackRateMbit;

    systemd.services.adaptive-upload-policy-qos = {
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
  };
}
