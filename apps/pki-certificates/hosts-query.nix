{ repo }:
let
  flake = builtins.getFlake "path:${repo}";
  allConfigurations =
    builtins.mapAttrs (_: value: {
      configuration = "nixosConfigurations";
      inherit value;
    }) flake.nixosConfigurations
    // builtins.mapAttrs (_: value: {
      configuration = "darwinConfigurations";
      inherit value;
    }) flake.darwinConfigurations;
  configurations = builtins.listToAttrs (
    builtins.filter (entry: entry.value.value.config.host.pki.realmAuthority != null) (
      map (name: {
        inherit name;
        value = allConfigurations.${name};
      }) (builtins.attrNames allConfigurations)
    )
  );
in
builtins.mapAttrs (
  _: entry:
  let
    host = entry.value.config.host;
  in
  {
    system = entry.value.config.nixpkgs.hostPlatform.system;
    inherit (entry) configuration;
    runtimeHost = entry.value.config.networking.hostName;
    inherit (host) realm;
  }
) configurations
