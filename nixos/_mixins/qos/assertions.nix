{ config, lib, ... }:
let
  profiles = config.host.qos.interfaces;
  profileNames = builtins.attrNames profiles;
  devices = map (name: profiles.${name}.device) profileNames;
in
{
  assertions = [
    {
      assertion = lib.all (name: builtins.match "^[A-Za-z0-9_]+$" name != null) profileNames;
      message = "host.qos.interfaces names may contain only letters, digits, and underscores";
    }
    {
      assertion = builtins.length devices == builtins.length (lib.unique devices);
      message = "each host.qos.interfaces profile must own a distinct device";
    }
    {
      assertion = lib.all (profileName: profiles.${profileName}.limits != { }) profileNames;
      message = "each host.qos.interfaces profile must define at least one limit";
    }
  ];
}
