{ config, ... }:
let
  username = config.host.username;
in
{
  host.isProxmox = true;
  host.network.primaryInterface = "enp3s0f0";
  host.ups = {
    server = {
      description = "APC UPS 1500VA";
    };
    shutdown.critical = true;
  };

  # Work machines do not use sops-managed login passwords.
  users.users = {
    root.hashedPassword = "$6$zoSR/.ZJMjOtERiO$Dm3aOpCiAMRlHT/SQ2mzIANa2zGZNUq2Iwuh35BTS.TtaTaKh7Y0aNxP4lxrsfXtcykMNhadUgMwXgf2c/7pz0";
    ${username}.hashedPassword =
      "$6$zoSR/.ZJMjOtERiO$Dm3aOpCiAMRlHT/SQ2mzIANa2zGZNUq2Iwuh35BTS.TtaTaKh7Y0aNxP4lxrsfXtcykMNhadUgMwXgf2c/7pz0";
  };
}
