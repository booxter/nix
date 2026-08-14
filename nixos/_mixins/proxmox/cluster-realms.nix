{ lib, outputs }:
let
  nodeConfigurations = lib.filterAttrs (
    _: configuration: configuration.config.host.proxmox.node != null
  ) outputs.nixosConfigurations;
  realmsByCluster = lib.foldl' (
    result: configuration:
    let
      host = configuration.config.host;
      cluster = host.proxmox.node.cluster;
    in
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
