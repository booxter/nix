{
  outputs,
  pkgs,
}:
let
  configurations = outputs.nixosConfigurations // outputs.darwinConfigurations;
  realmsByHost = pkgs.lib.mapAttrs (_: configuration: configuration.config.host.realm) configurations;
in
{
  packages = {
    sops-tools = import ./package.nix { inherit pkgs realmsByHost; };
  };
}
