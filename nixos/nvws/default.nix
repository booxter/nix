{ config, ... }:
let
  username = config.host.username;
in
{
  system.stateVersion = "25.11";

  hardware.cpu.intel.updateMicrocode = true;

  host = {
    disko.layout = "plain";
    realm = "work";
    nix.builder = {
      enable = true;
      hostName = "nvws.local";
    };
    proxmox.node = {
      cluster = "nvws";
      controller = { };
    };
    network.interfaces.enp3s0f0 = { };
  };
  host.ups = {
    server = {
      description = "APC UPS 1500VA";
      waitForLowBattery = true;
    };
  };

  # Work machines do not use sops-managed login passwords.
  users.users = {
    root.hashedPassword = "$6$zoSR/.ZJMjOtERiO$Dm3aOpCiAMRlHT/SQ2mzIANa2zGZNUq2Iwuh35BTS.TtaTaKh7Y0aNxP4lxrsfXtcykMNhadUgMwXgf2c/7pz0";
    ${username}.hashedPassword =
      "$6$zoSR/.ZJMjOtERiO$Dm3aOpCiAMRlHT/SQ2mzIANa2zGZNUq2Iwuh35BTS.TtaTaKh7Y0aNxP4lxrsfXtcykMNhadUgMwXgf2c/7pz0";
  };
}
