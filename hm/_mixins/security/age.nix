{
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  identity = osConfig.host.security.secrets.operator.ageIdentity;
in
{
  config = lib.mkIf (identity != null) {
    home.sessionVariables.SOPS_AGE_KEY_FILE = identity.path;
    home.packages = lib.optional (identity.backend == "yubikey") pkgs.age-plugin-yubikey;
  };
}
