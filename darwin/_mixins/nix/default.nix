{
  config,
  lib,
  ...
}:
let
  hasAttic = config.host.attic.realmServers != { };
in
{
  imports = [
    ./builder-observability.nix
    ./cache-preference.nix
    ./cache-warmer
    ./linux-builder.nix
    ./nixpkgs-review.nix
    ./open.nix
  ];

  nix.gc.interval = [
    (
      {
        Hour = 3;
        Minute = 15;
      }
      // lib.optionalAttrs (!hasAttic) { Weekday = 6; }
    )
  ];
  nix.optimise.interval = [
    {
      Hour = 4;
      Minute = 15;
    }
  ];
  nix.settings.sandbox = "relaxed";

  system.activationScripts.postActivation.text = lib.mkAfter ''
    if [ -d /nix/store ]; then
      echo "Hiding the Nix store from macOS metadata services."
      /usr/bin/chflags hidden /nix

      if [ ! -e /nix/.metadata_never_index ]; then
        /usr/bin/install -m 0644 -o root -g wheel /dev/null /nix/.metadata_never_index
      fi

      /usr/bin/install -d -m 0700 -o root -g wheel /nix/.fseventsd
      if [ ! -e /nix/.fseventsd/no_log ]; then
        /usr/bin/install -m 0600 -o root -g wheel /dev/null /nix/.fseventsd/no_log
      fi
    fi
  '';
}
