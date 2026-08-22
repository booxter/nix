{
  config,
  fleetInventory,
  lib,
  ...
}:
let
  localVnc = config.host.remote-control.inventory.vnc;
  inventoryVnc = fleetInventory.hosts.${config.networking.hostName}.remoteControl.vnc;
in
{
  options.host.remote-control.inventory.vnc = lib.mkOption {
    type =
      with lib.types;
      nullOr (submodule {
        options = {
          connection = lib.mkOption {
            type = enum [
              "direct"
              "ssh-tunnel"
            ];
          };
          displays = lib.mkOption {
            type = listOf (submodule {
              options = {
                name = lib.mkOption { type = nonEmptyStr; };
                port = lib.mkOption { type = port; };
                primary = lib.mkOption { type = bool; };
              };
            });
          };
        };
      });
    default = null;
    internal = true;
    description = "Resolved VNC connection information published to remote-control clients.";
  };

  config.assertions = [
    {
      assertion = (localVnc != null) == (inventoryVnc != null);
      message = "local VNC server configuration and fleet inventory must agree";
    }
    {
      assertion = localVnc == null || inventoryVnc == null || localVnc == inventoryVnc;
      message = "local VNC connection information must match fleet inventory";
    }
  ];
}
