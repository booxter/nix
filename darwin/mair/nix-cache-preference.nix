{
  config,
  hostInventory,
  lib,
  pkgs,
  username,
  ...
}:
let
  nixCaches = hostInventory.site.nixCaches;
  extraSubstituters = lib.remove nixCaches.flakehub.url (
    config.nix.settings."extra-substituters" or [ ]
  );
  cacheSubstituters =
    preferHomeCache:
    [
      nixCaches.nixos.url
      (if preferHomeCache then nixCaches.home.lanUrl else nixCaches.home.vpnUrl)
    ]
    ++ extraSubstituters
    ++ [
      (if preferHomeCache then nixCaches.flakehub.lanUrl else nixCaches.flakehub.vpnUrl)
    ];
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
