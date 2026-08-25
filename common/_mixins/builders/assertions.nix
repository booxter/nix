{
  config,
  fleetInventory,
  lib,
  outputs,
  ...
}:
let
  builder = config.host.nix.builder;
  hostName = config.networking.hostName;
  inventoryBuilder = fleetInventory.builders.${hostName} or null;
  localBuilder =
    if builder == null then
      null
    else
      {
        inherit (builder)
          hostName
          maxJobs
          speedFactor
          supportedFeatures
          uses
          ;
        realm = config.host.realm;
        system = config.nixpkgs.hostPlatform.system;
      };
  managedConfigurations = outputs.nixosConfigurations // outputs.darwinConfigurations;
  invalidInventoryBuilders = builtins.filter (name: !(builtins.hasAttr name managedConfigurations)) (
    builtins.attrNames fleetInventory.builders
  );
  hostNames =
    map (entry: entry.hostName) (builtins.attrValues config.host.nix.builder-pool)
    ++ lib.optional (builder != null) builder.hostName;
in
{
  config.assertions = [
    {
      assertion = builtins.length hostNames == builtins.length (lib.unique hostNames);
      message = "Nix builders in realm '${config.host.realm}' must advertise unique hostnames";
    }
    {
      assertion = (builder != null) == (inventoryBuilder != null);
      message = "local Nix builder configuration and fleet inventory must agree";
    }
    {
      assertion = invalidInventoryBuilders == [ ];
      message = "Nix builder inventory entries must name managed hosts";
    }
    {
      assertion = localBuilder == null || inventoryBuilder == null || localBuilder == inventoryBuilder;
      message = "local Nix builder configuration must match fleet inventory";
    }
    {
      assertion = builder == null || builder.maxJobs <= config.nix.nrBuildUsers;
      message = "managed Nix builder maxJobs must not exceed nix.nrBuildUsers";
    }
  ];
}
