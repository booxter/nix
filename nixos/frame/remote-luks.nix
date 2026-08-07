{ hostInventory, ... }:
let
  unlockKey =
    publicKey:
    ''no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-user-rc,command="systemctl default" ${publicKey}'';
  unlockIdentities = hostInventory.ssh.identitiesForPurpose hostInventory.ssh.purposes.remoteUnlock;
in
{
  boot.initrd = {
    availableKernelModules = [ "r8169" ];
    network = {
      enable = true;
      ssh = {
        enable = true;
        hostKeys = [ "/etc/secrets/initrd/ssh_host_ed25519_key" ];
        authorizedKeys = map (identity: unlockKey identity.publicKey) unlockIdentities;
      };
    };
    systemd.network = {
      enable = true;
      networks."10-enp191s0" = {
        matchConfig.Name = "enp191s0";
        networkConfig.DHCP = "ipv4";
        linkConfig.RequiredForOnline = "routable";
      };
    };
  };
}
