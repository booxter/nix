{ config, ... }:
let
  username = config.host.username;
in
{
  system.stateVersion = "25.11";

  hardware.cpu.intel.updateMicrocode = true;

  host = {
    realm = "work";
    nix.builder = {
      enable = true;
      hostName = "nvws.local";
    };
    proxmox = {
      cluster = "nvws";
      node.enable = true;
    };
    network = {
      interfaces.enp3s0f0.kind = "ethernet";
      macAddress = "ac:b4:80:40:05:2e";
      primaryInterface = "enp3s0f0";
      reservation = {
        enable = true;
        address = "192.168.15.100";
      };
    };
  };
  host.ups = {
    server = {
      enable = true;
      description = "APC UPS 1500VA";
    };
    shutdown.waitForLowBattery = true;
  };
  host.user.passwords.sops.enable = false;

  # Work machines do not use sops-managed login passwords.
  users.users = {
    root.hashedPassword = "$6$zoSR/.ZJMjOtERiO$Dm3aOpCiAMRlHT/SQ2mzIANa2zGZNUq2Iwuh35BTS.TtaTaKh7Y0aNxP4lxrsfXtcykMNhadUgMwXgf2c/7pz0";
    ${username}.hashedPassword =
      "$6$zoSR/.ZJMjOtERiO$Dm3aOpCiAMRlHT/SQ2mzIANa2zGZNUq2Iwuh35BTS.TtaTaKh7Y0aNxP4lxrsfXtcykMNhadUgMwXgf2c/7pz0";
  };
}
