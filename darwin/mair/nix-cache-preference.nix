{
  config,
  lib,
  pkgs,
  ...
}:
let
  username = config.host.username;
  caches = builtins.attrValues config.host.nix.caches;
  substituterFor =
    profile: cache:
    let
      profilePriority = cache.priorities.${profile};
      priority = if profilePriority == null then cache.priorities.default else profilePriority;
    in
    cache.substituter + lib.optionalString (priority != null) "?priority=${toString priority}";
  cacheSubstituters =
    preferHomeCache: map (substituterFor (if preferHomeCache then "lan" else "vpn")) caches;
  lanSubstituters = lib.concatStringsSep " " (cacheSubstituters true);
  vpnSubstituters = lib.concatStringsSep " " (cacheSubstituters false);
  nixCachePreferenceWrapper = pkgs.writeShellApplication {
    name = "nix";
    text = ''
      if [ -e /var/run/wireguard/wg0.name ]; then
        substituters=${lib.escapeShellArg vpnSubstituters}
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
  home-manager.users.${username}.home.sessionPath = lib.mkBefore [
    "${nixCachePreferenceWrapper}/bin"
  ];
}
