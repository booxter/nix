{ config, lib, ... }:
let
  guards = config.host.maintenance.guards;
  switchGuards = lib.filterAttrs (_: guard: builtins.elem "switch" guard.before) guards;
in
{
  options.host.maintenance.guards = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          command = lib.mkOption {
            type = lib.types.nonEmptyStr;
            description = "Command that must complete before maintenance proceeds.";
          };

          before = lib.mkOption {
            type = lib.types.listOf (
              lib.types.enum [
                "upgrade"
                "switch"
                "reboot"
              ]
            );
            description = "Maintenance operations guarded by this command.";
          };

          waitIndefinitely = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether maintenance may wait indefinitely for this guard.";
          };
        };
      }
    );
    default = { };
    description = "Conditions that must be satisfied before disruptive maintenance.";
  };

  config.system.preSwitchChecks = lib.mapAttrs (_name: guard: ''
    if [ "''${2-}" = switch ]; then
      ${guard.command}
    fi
  '') switchGuards;
}
