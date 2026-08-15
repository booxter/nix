{ repo }:
let
  flake = builtins.getFlake "path:${repo}";
  providers = builtins.filter (entry: entry.value.config.host.sso.provider != null) (
    map (name: {
      inherit name;
      value = flake.nixosConfigurations.${name};
    }) (builtins.attrNames flake.nixosConfigurations)
  );
in
builtins.listToAttrs (
  map (entry: {
    name = entry.value.config.host.realm;
    value = entry.value.config.networking.hostName;
  }) providers
)
