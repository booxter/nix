{
  config,
  lib,
  pkgs,
  qosModel,
  ...
}:
let
  cfg = config.host.qos;
  targets = lib.concatMap (
    profile:
    lib.mapAttrsToList
      (limit: rule: {
        inherit profile limit;
        inherit (rule) direction;
        device =
          if rule.direction == "ingress" then
            qosModel.profileData.${profile}.ifbInterfaces.${limit}
          else
            cfg.interfaces.${profile}.device;
        parent = if rule.direction == "ingress" then "root" else qosModel.classIds.${profile}.${limit};
      })
      (
        lib.filterAttrs (
          _: rule: rule.queue == "cake" || (rule.queue == null && rule.direction == "ingress")
        ) cfg.interfaces.${profile}.limits
      )
  ) qosModel.profileNames;
  package = pkgs.callPackage ./pkgs/cake-metrics { atomicFileWrites = pkgs.atomic-file-writes; };
  producer = config.host.observability.nodeExporter.textfile.periodicProducers.cake-metrics;
in
{
  imports = [
    ../observability/textfile-producers.nix
    ../../../common/_mixins/observability/textfiles.nix
  ];
  options.host.qos.metrics.enable = lib.mkEnableOption "CAKE state metrics" // {
    default = (config.host.observability.enable or false) && targets != [ ];
  };

  config = lib.mkIf cfg.metrics.enable {
    host.observability.nodeExporter.textfile.periodicProducers.cake-metrics = {
      description = "Collect CAKE queue and congestion-control state";
      interval = "5s";
      accuracySec = "1s";
      addressFamilies = [
        "AF_UNIX"
        "AF_NETLINK"
      ];
      after = map (profile: "qos-${profile}.service") qosModel.profileNames;
      command = [
        (lib.getExe package)
        "--config"
        (toString ((pkgs.formats.json { }).generate "cake-metrics.json" targets))
        "--output"
        "${producer.directory}/cake.prom"
      ];
    };
  };
}
