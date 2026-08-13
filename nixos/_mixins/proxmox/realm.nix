{
  config,
  lib,
  outputs,
  ...
}:
let
  clusterRealms = import ./cluster-realms.nix { inherit lib outputs; };
  cluster = config.host.proxmox.cluster;
  clusterRealm = clusterRealms.${cluster} or (throw "unknown Proxmox cluster '${cluster}'");
in
{
  config = lib.mkIf config.host.proxmox.guest.enable {
    host.realm = lib.mkDefault clusterRealm;
  };
}
