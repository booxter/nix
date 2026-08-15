{ config, lib, ... }:
let
  guards = config.host.maintenance.guards;
in
{
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
