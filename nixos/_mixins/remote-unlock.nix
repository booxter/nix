{
  config,
  hostInventory,
  lib,
  ...
}:
let
  cfg = config.host.boot.remoteUnlock;
  interface = if cfg.interface == null then "missing" else cfg.interface;
  unlockKey =
    publicKey:
    ''no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-user-rc,command="systemctl default" ${publicKey}'';
  unlockIdentities = hostInventory.ssh.identitiesForPurpose hostInventory.ssh.purposes.remoteUnlock;
in
{
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.host.boot.requiresInteractiveUnlock;
        message = "Remote initrd unlock requires an interactively unlocked system disk";
      }
      {
        assertion = cfg.interface != null;
        message = "Remote initrd unlock requires an inventory network interface";
      }
      {
        assertion = unlockIdentities != [ ];
        message = "Remote initrd unlock requires at least one authorized SSH identity";
      }
    ];

    boot.initrd = {
      availableKernelModules = cfg.kernelModules;
      network = {
        enable = true;
        ssh = {
          enable = true;
          # TODO: source this dedicated key from a neededForUsers SOPS secret
          # after verifying that initial activation decrypts it before GRUB
          # appends secrets to every generated initrd.
          hostKeys = [ "/etc/secrets/initrd/ssh_host_ed25519_key" ];
          authorizedKeys = map (identity: unlockKey identity.publicKey) unlockIdentities;
        };
      };
      systemd.network = {
        enable = true;
        networks."10-${interface}" = {
          matchConfig.Name = interface;
          networkConfig.DHCP = "ipv4";
          linkConfig.RequiredForOnline = "routable";
        };
      };
    };
  };
}
