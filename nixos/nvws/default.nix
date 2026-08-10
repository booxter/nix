{ config, ... }:
let
  username = config.host.username;
in
{
  system.stateVersion = "25.11";

  host = {
    nix.builder = {
      enable = true;
      hostName = "nvws.local";
    };
    isProxmox = true;
    network = {
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
      description = "APC UPS 1500VA";
    };
    shutdown.waitForLowBattery = true;
  };

  # Work machines do not use sops-managed login passwords.
  users.users = {
    root.hashedPassword = "$6$zoSR/.ZJMjOtERiO$Dm3aOpCiAMRlHT/SQ2mzIANa2zGZNUq2Iwuh35BTS.TtaTaKh7Y0aNxP4lxrsfXtcykMNhadUgMwXgf2c/7pz0";
    ${username}.hashedPassword =
      "$6$zoSR/.ZJMjOtERiO$Dm3aOpCiAMRlHT/SQ2mzIANa2zGZNUq2Iwuh35BTS.TtaTaKh7Y0aNxP4lxrsfXtcykMNhadUgMwXgf2c/7pz0";
  };
}
