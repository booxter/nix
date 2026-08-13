{ lib, outputs }:
let
  nodeConfigurations = lib.filterAttrs (
    _: configuration: configuration.config.host.proxmox.node.enable
  ) outputs.nixosConfigurations;
  realmsByCluster = lib.foldl' (
    result: configuration:
    let
      host = configuration.config.host;
      cluster = host.proxmox.cluster;
    in
    assert lib.assertMsg (
      cluster != null
    ) "Proxmox node '${configuration.config.networking.hostName}' must claim a cluster";
    result
    // {
      ${cluster} = lib.unique ((result.${cluster} or [ ]) ++ [ host.realm ]);
    }
  ) { } (builtins.attrValues nodeConfigurations);
in
lib.mapAttrs (
  cluster: realms:
  assert lib.assertMsg (
    builtins.length realms == 1
  ) "Proxmox cluster '${cluster}' must belong to exactly one realm";
  builtins.head realms
) realmsByCluster
