{
  config,
  lib,
  pkgs,
  ...
}:
let
  username = config.host.username;
  caches = builtins.attrValues config.host.nix.caches;
  internalNetworks = lib.unique (
    map (cache: cache.reachability.network) (
      builtins.filter (cache: cache.reachability.kind == "internal") caches
    )
  );
  clients = builtins.attrValues config.host.network.wireguardClients;
  relevantClients = builtins.filter (
    client: lib.intersectLists client.providesAccessTo internalNetworks != [ ]
  ) clients;
  enable = config.host.hardware.isLaptop && relevantClients != [ ];
  cacheLib = import ../../../common/_mixins/nix/cache/lib.nix { inherit lib; };
  substitutersFor = profile: map (cacheLib.substituterFor profile) caches;
  tunnelInactiveSubstituters = lib.concatStringsSep " " (substitutersFor "tunnelInactive");
  tunnelActiveSubstituters = lib.concatStringsSep " " (substitutersFor "tunnelActive");
  tunnelActiveCheck = lib.concatMapStringsSep " || " (
    client: "[ -e ${lib.escapeShellArg "/var/run/wireguard/${client.interface}.name"} ]"
  ) relevantClients;
  wrapper = pkgs.writeShellApplication {
    name = "nix";
    text = ''
      if ${tunnelActiveCheck}; then
        substituters=${lib.escapeShellArg tunnelActiveSubstituters}
      else
        substituters=${lib.escapeShellArg tunnelInactiveSubstituters}
      fi

      # Keep wrapper options out of argv so NIX_GET_COMPLETIONS indexes from
      # shell completion still refer to the user's original command words.
      if [ -n "''${NIX_CONFIG:-}" ]; then
        NIX_CONFIG="''${NIX_CONFIG}"$'\n'"substituters = $substituters"
      else
        NIX_CONFIG="substituters = $substituters"
      fi
      export NIX_CONFIG

      exec ${lib.getExe config.nix.package} "$@"
    '';
  };
in
{
  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = lib.all (
            client: builtins.hasAttr client.interface config.networking.wg-quick.interfaces
          ) clients;
          message = "host.network.wireguardClients must reference configured networking.wg-quick interfaces on Darwin";
        }
      ];
    }
    (lib.mkIf enable {
      home-manager.users.${username}.home.sessionPath = lib.mkBefore [ "${wrapper}/bin" ];
    })
  ];
}
