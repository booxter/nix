{ config, lib, ... }:
let
  guards = config.host.maintenance.guards;
in
{
  imports = [ ./vacations.nix ];

  options.host.maintenance.holds = lib.mkOption {
    type = with lib.types; attrsOf nonEmptyStr;
    default = { };
    internal = true;
    description = ''
      Commands checked before unattended maintenance. Exit zero to proceed or
      1–254 to skip this run, following systemd ExecCondition semantics.
    '';
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
