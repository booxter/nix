{
  config,
  lib,
  outputs,
  ...
}:
let
  clusterRealms = import ./cluster-realms.nix { inherit lib outputs; };
  cluster = config.host.proxmox.guest.cluster;
  clusterRealm = clusterRealms.${cluster} or (throw "unknown Proxmox cluster '${cluster}'");
in
{
  config = lib.mkIf (config.host.proxmox.guest != null) {
    host.realm = lib.mkDefault clusterRealm;
  };
}
