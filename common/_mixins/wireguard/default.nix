{
  config,
  facts,
  lib,
  ...
}:
let
  hostname = config.networking.hostName;
  networks = facts.site.wireguard;
  serverNetworks = builtins.attrNames (
    lib.filterAttrs (_: network: network.gateway.host == hostname) networks
  );
  clientNetworks = builtins.attrNames (
    lib.filterAttrs (
      _: network: lib.any (peer: (peer.host or null) == hostname) (builtins.attrValues network.peers)
    ) networks
  );
  only = values: if builtins.length values == 1 then builtins.head values else null;
  networkType = with lib.types; nullOr (enum (builtins.attrNames networks));
  interfaceOption =
    description:
    lib.mkOption {
      type = lib.types.strMatching "[A-Za-z0-9_.-]+";
      default = "wg0";
      inherit description;
    };
in
{
  imports = [
    ./assertions.nix
    ./client.nix
  ];

  options.host.wireguard = {
    server = {
      network = lib.mkOption {
        type = networkType;
        default = only serverNetworks;
        readOnly = true;
        internal = true;
        description = "WireGuard network served by this host according to fleet facts.";
      };

      interface = interfaceOption "Network interface used by the WireGuard server.";
    };

    client = {
      network = lib.mkOption {
        type = networkType;
        default = only clientNetworks;
        readOnly = true;
        internal = true;
        description = "WireGuard network this host joins according to fleet facts.";
      };

      interface = interfaceOption "Network interface used by the WireGuard client.";

      autostart = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether to start the WireGuard client automatically.";
      };
    };
  };
}
