{ lib, ... }:
let
  readPublicKey = path: lib.removeSuffix "\n" (builtins.readFile path);
  unlockKey =
    path:
    ''no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-user-rc,command="systemctl default" ${readPublicKey path}'';
in
{
  boot.initrd = {
    availableKernelModules = [ "r8169" ];
    network = {
      enable = true;
      ssh = {
        enable = true;
        hostKeys = [ "/etc/secrets/initrd/ssh_host_ed25519_key" ];
        authorizedKeys = [
          (unlockKey ../../public-keys/users/mair.pub)
          (unlockKey ../../public-keys/users/mmini.pub)
        ];
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
