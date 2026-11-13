{
  fleetHosts,
  lib,
}:
let
  ssh = import ./ssh { inherit lib; };
  hosts = import ./hosts.nix { inherit fleetHosts lib ssh; };
  webIngress = import ./web-ingress.nix;
  webServices = import ./web-services-model.nix {
    entriesByOwner = import ./web-services.nix;
    inherit
      hosts
      lib
      webIngress
      ;
  };
in
{
  atticServers = import ./attic.nix { inherit lib; };
  autoUpgrade = import ./auto-upgrade.nix;
  builders = import ./builders.nix { inherit lib; };
  builderSigningKeys = import ./builders/signing-keys { inherit lib; };
  dashboard = import ./dashboard.nix;
  inherit hosts;
  inherit ssh;
  observability = import ./observability.nix;
  proxmox = import ./proxmox.nix;
  ups = import ./ups.nix;
  inherit webIngress;
  inherit webServices;
  wireguard = import ./wireguard.nix;
  yubikeys = import ./yubikeys.nix;
}
