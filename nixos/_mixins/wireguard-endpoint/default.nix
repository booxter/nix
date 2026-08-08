{
  config,
  hostInventory,
  lib,
  ...
}:
let
  hostname = config.networking.hostName;
  ownedEndpointNames = builtins.attrNames (
    lib.filterAttrs (_: endpoint: endpoint.gateway.host == hostname) hostInventory.site.wireguard
  );
in
{
  imports = [
    ./ddns.nix
    ./network.nix
    ./observability.nix
    ./qos.nix
  ];

  options.host.wireguardEndpoint = {
    name = lib.mkOption {
      type = with lib.types; nullOr str;
      default =
        if builtins.length ownedEndpointNames == 1 then builtins.head ownedEndpointNames else null;
      readOnly = true;
      internal = true;
      description = "WireGuard endpoint assigned to this host by inventory.";
    };

    interface = lib.mkOption {
      type = lib.types.str;
      default = "wg0";
      description = "Network interface used by the WireGuard endpoint.";
    };
  };

  config.assertions = [
    {
      assertion = builtins.length ownedEndpointNames <= 1;
      message = "host ${hostname} may own at most one WireGuard endpoint";
    }
  ];
}
