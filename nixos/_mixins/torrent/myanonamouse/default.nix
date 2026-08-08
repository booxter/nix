{
  config,
  hostInventory,
  lib,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.host.myanonamouse;
  hostname = config.networking.hostName;
  service = hostInventory.servicesById.myanonamouse;
  instance = service.instances.${hostname} or { };
  vpnRequirement = instance.vpnConfinement or { };
  targetIds = instance.registersIpFor or [ ];
  unknownTargetIds = builtins.filter (
    targetId: !builtins.hasAttr targetId hostInventory.servicesById
  ) targetIds;
  targetServices = map (targetId: hostInventory.servicesById.${targetId}) (
    lib.subtractLists unknownTargetIds targetIds
  );
  nonLocalTargetIds = map (target: target.id) (
    builtins.filter (target: !hostInventory.serviceRunsOn hostname target) targetServices
  );
  mismatchedVpnTargetIds = map (target: target.id) (
    builtins.filter (
      target:
      let
        targetInstance = target.instances.${hostname} or { };
      in
      !(targetInstance ? vpnConfinement)
      || targetInstance.vpnConfinement.profile != (vpnRequirement.profile or null)
    ) targetServices
  );
  package = pkgs.callPackage ./package {
    atomicFileWrites = pkgs.atomic-file-writes;
  };
  unitName = "myanonamouse-ip-update";
in
{
  options.host.myanonamouse.enable = lib.mkOption {
    type = lib.types.bool;
    default = hostInventory.serviceRunsOn hostname service;
    readOnly = true;
    internal = true;
    description = "Whether inventory assigns MyAnonamouse IP registration to this host.";
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = instance ? cookiePath && instance ? vpnConfinement;
        message = "The MyAnonamouse inventory instance must define a cookie path and VPN confinement.";
      }
      {
        assertion = targetIds != [ ];
        message = "The MyAnonamouse inventory instance must register an IP for at least one service.";
      }
      {
        assertion = unknownTargetIds == [ ];
        message = "MyAnonamouse references unknown services: ${lib.concatStringsSep ", " unknownTargetIds}";
      }
      {
        assertion = nonLocalTargetIds == [ ];
        message = "MyAnonamouse must be colocated with the services whose IP it registers: ${lib.concatStringsSep ", " nonLocalTargetIds}";
      }
      {
        assertion = mismatchedVpnTargetIds == [ ];
        message = "MyAnonamouse must share a VPN profile with the services whose IP it registers: ${lib.concatStringsSep ", " mismatchedVpnTargetIds}";
      }
    ];

    systemd.services.${unitName} = {
      serviceConfig = {
        Type = "oneshot";
        UMask = "0077";
        ExecStart = utils.escapeSystemdExecArgs [
          (lib.getExe package)
          "--cookie-jar"
          instance.cookiePath
        ];
      };
    };

    systemd.timers.${unitName} = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "10m";
        OnUnitActiveSec = "1h";
        RandomizedDelaySec = "10m";
        Unit = "${unitName}.service";
      };
    };

    host.vpnConfinement.implementations.myanonamouse = {
      serviceEnabled = true;
      systemdUnits = [ unitName ];
    };
  };
}
