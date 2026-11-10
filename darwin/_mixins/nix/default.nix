{
  config,
  inputs,
  lib,
  ...
}:
let
  hasAttic = config.host.attic.realmServers != { };
  gc = config.services.fast-nix-gc;
in
{
  imports = [
    inputs.fast-nix-gc.darwinModules.default
    ./builder-observability.nix
    ./cache-preference.nix
    ./linux-builder.nix
    ./nixpkgs-review.nix
    ./open.nix
  ];

  nix.gc.automatic = true;
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

  # Use the native store-wait wrapper until the upstream job uses command.
  launchd.daemons.nix-gc = lib.mkIf config.nix.gc.automatic {
    path = [ config.nix.package ];
    command = lib.mkForce (
      lib.escapeShellArgs (
        [ (lib.getExe gc.package) ]
        ++ lib.optionals (gc.deleteOlderThan != null) [
          "--delete-older-than"
          gc.deleteOlderThan
        ]
      )
    );
  };

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
