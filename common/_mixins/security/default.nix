{
  config,
  facts,
  lib,
  ...
}:
let
  realm = facts.realms.${config.host.realm};
in
{
  options.host.security.sudo.wheelNeedsPassword = lib.mkOption {
    type = lib.types.bool;
    default = realm.management.sudoWheelNeedsPassword;
    readOnly = true;
    internal = true;
    description = "Whether wheel users must enter a password for sudo.";
  };
}
