{ lib, ... }:
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
}
