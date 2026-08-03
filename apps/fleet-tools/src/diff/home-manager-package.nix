let
  flake = builtins.getFlake (builtins.getEnv "DIFF_FLAKE_REF");
  kind = builtins.getEnv "DIFF_TARGET_KIND";
  name = builtins.getEnv "DIFF_MACHINE";
  user = builtins.getEnv "DIFF_HOME_MANAGER_USER";
  attribute = builtins.getEnv "DIFF_HOME_MANAGER_ATTRIBUTE";
  configurations =
    if kind == "nixos" then
      flake.nixosConfigurations
    else if kind == "darwin" then
      flake.darwinConfigurations
    else
      { };
  configuration = builtins.getAttr name configurations;
  home = (builtins.getAttr user configuration.config."home-manager".users).home;
in
builtins.getAttr attribute home
