{
  config,
  lib,
  ...
}:
let
  layout = config.host.disko.layout;
  cfg = if builtins.isAttrs layout then layout.remoteUnlock else null;
  unlockKey =
    key:
    ''no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-user-rc,command="systemctl default" ${key}'';
in
{
  config = lib.mkIf (cfg != null) {
    boot.initrd = {
      availableKernelModules = cfg.kernelModules;
      network = {
        enable = true;
        ssh = {
          enable = true;
          hostKeys = [ cfg.hostKeyPath ];
          authorizedKeys = map unlockKey cfg.authorizedKeys;
        };
      };
      systemd.network = {
        enable = true;
        networks = {
          "10-${cfg.networkInterface}" = {
            matchConfig.Name = cfg.networkInterface;
            networkConfig.DHCP = "ipv4";
            linkConfig.RequiredForOnline = "routable";
          };
        };
      };
    };
  };
}
