let
  flake = builtins.getFlake (builtins.getEnv "DIFF_FLAKE_REF");
  kind = builtins.getEnv "DIFF_TARGET_KIND";
  name = builtins.getEnv "DIFF_MACHINE";
  configurations =
    if kind == "nixos" then
      flake.nixosConfigurations
    else if kind == "darwin" then
      flake.darwinConfigurations
    else
      { };
  configuration = builtins.getAttr name configurations;
  homeManager =
    if builtins.hasAttr "home-manager" configuration.config then
      configuration.config."home-manager"
    else
      { };
  users = if builtins.hasAttr "users" homeManager then builtins.attrNames homeManager.users else [ ];
in
users
