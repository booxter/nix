{
  config,
  lib,
  outputs,
  pkgs,
  ...
}:
let
  configurations = outputs.darwinConfigurations // outputs.nixosConfigurations;
  vncHosts = builtins.filter (host: host.vnc != null) (
    lib.mapAttrsToList (name: configuration: {
      inherit name;
      vnc = configuration.config.host.remote-control.inventory.vnc;
    }) configurations
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
