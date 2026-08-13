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
  client = config.host.wireguard.client;
  enable =
    config.host.hardware.isLaptop && client.enable && builtins.elem client.network internalNetworks;
  cacheLib = import ../../../common/_mixins/nix/cache/lib.nix { inherit lib; };
  substitutersFor = profile: map (cacheLib.substituterFor profile) caches;
  lanSubstituters = lib.concatStringsSep " " (substitutersFor "lan");
  wanSubstituters = lib.concatStringsSep " " (substitutersFor "wan");
  tunnelActiveCheck = "[ -e ${lib.escapeShellArg "/var/run/wireguard/${client.interface}.name"} ]";
  wrapper = pkgs.writeShellApplication {
    name = "nix";
    text = ''
      if ${tunnelActiveCheck}; then
        substituters=${lib.escapeShellArg wanSubstituters}
      else
        substituters=${lib.escapeShellArg lanSubstituters}
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
  config = lib.mkIf enable {
    home-manager.users.${username}.home.sessionPath = lib.mkBefore [ "${wrapper}/bin" ];
  };
}
