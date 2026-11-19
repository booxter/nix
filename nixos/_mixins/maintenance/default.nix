{ config, lib, ... }:
let
  guards = config.host.maintenance.guards;
in
{
  imports = [ ./vacations.nix ];

  options.host.maintenance.holds = lib.mkOption {
    type =
      with lib.types;
      attrsOf (submodule {
        options = {
          scope = lib.mkOption {
            type = enum [
              "full"
              "reboot"
            ];
            description = "Hold upgrades and reboots (full), or only reboots (reboot).";
          };
          condition = lib.mkOption {
            type = nonEmptyStr;
            description = ''
              Command checked before maintenance. Exit zero to proceed or 1–254
              to skip this run, following systemd ExecCondition semantics.
            '';
          };
        };
      });
    default = { };
    internal = true;
    description = "Named holds on unattended maintenance.";
  };

  options.host.maintenance.guards = lib.mkOption {
    type = with lib.types; attrsOf nonEmptyStr;
    default = { };
    internal = true;
    description = "Conditions that must be satisfied before disruptive maintenance.";
  };

  config.system.preSwitchChecks = lib.mapAttrs (_name: command: ''
    if [ "''${2-}" = switch ]; then
      ${command}
    fi
  '') guards;
}
