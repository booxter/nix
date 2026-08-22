{
  config,
  fleetInventory,
  lib,
  pkgs,
  ...
}:
let
  vncHosts = builtins.filter (host: host.vnc != null) (
    lib.mapAttrsToList (name: host: {
      inherit name;
      vnc = host.remoteControl.vnc;
    }) fleetInventory.hosts
  );
  directHosts = builtins.filter (host: host.vnc.connection == "direct") vncHosts;
  tunneledHosts = builtins.filter (host: host.vnc.connection == "ssh-tunnel") vncHosts;

  vncOpen = pkgs.callPackage ./vnc-open {
    inherit directHosts tunneledHosts;
  };
in
{
  environment.systemPackages = lib.mkIf (config.host.remote-control.client.vnc != null) [ vncOpen ];
}
