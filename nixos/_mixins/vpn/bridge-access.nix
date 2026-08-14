{
  lib,
  vpnModel,
  pkgs,
  utils,
  ...
}:
let
  model = vpnModel;
  bridgeAccessPackage = pkgs.callPackage ./pkgs/bridge-access { };
  serviceFor =
    namespaceName: namespace:
    let
      serviceName = "vpn-${namespaceName}-bridge-access";
      namespaceUnit = "${namespaceName}.service";
      bridgeAccessConfig = (pkgs.formats.json { }).generate "${serviceName}.json" {
        namespace = namespaceName;
        sourceAddress = namespace.bridgeAddress;
        tcpPorts = model.bridgeTcpPorts.${namespaceName};
      };
      command =
        action:
        utils.escapeSystemdExecArgs [
          (lib.getExe bridgeAccessPackage)
          action
          "--config"
          bridgeAccessConfig
        ];
    in
    lib.nameValuePair serviceName {
      wantedBy = [ "multi-user.target" ];
      unitConfig = {
        After = [ namespaceUnit ];
        BindsTo = [ namespaceUnit ];
        PartOf = [ namespaceUnit ];
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = command "apply";
        ExecStop = command "remove";
      };
    };
  services = lib.mapAttrs' serviceFor (
    lib.filterAttrs (name: _: model.bridgeTcpPorts.${name} != [ ]) model.enabledNamespaces
  );
in
{
  config = lib.mkIf model.active {
    systemd.services = services;
  };
}
