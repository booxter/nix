{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.host.network.ethernet.disablePauseFrames;
  declaredEthernetInterfaces = builtins.attrNames (
    lib.filterAttrs (_: interface: interface.kind == "ethernet") config.host.network.interfaces
  );
  interfaces = lib.unique cfg.interfaces;
  mkService = interface: {
    description = "Disable Ethernet pause frames on ${interface}";
    after = [ "network-pre.target" ];
    wants = [ "network-pre.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = utils.escapeSystemdExecArgs [
        (lib.getExe pkgs.ethtool)
        "-A"
        interface
        "autoneg"
        "off"
        "rx"
        "off"
        "tx"
        "off"
      ];
      RemainAfterExit = true;
    };
  };
in
{
  imports = [ ./assertions.nix ];

  options.host.network.ethernet.disablePauseFrames = {
    enable = lib.mkEnableOption "disabling Ethernet pause frames";

    interfaces = lib.mkOption {
      type = with lib.types; listOf nonEmptyStr;
      default = declaredEthernetInterfaces;
      description = "Declared Ethernet interfaces on which pause frames should be disabled.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services = builtins.listToAttrs (
      map (interface: {
        name = "ethtool-${interface}-disable-pause";
        value = mkService interface;
      }) interfaces
    );
  };
}
