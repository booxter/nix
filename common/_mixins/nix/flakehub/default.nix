{
  config,
  inputs,
  lib,
  ...
}:
let
  flakehubCacheKeys =
    let
      # FlakeHub does not expose a separate machine-readable cache key
      # manifest. Determinate's installer is the upstream source that writes
      # these keys into nix.conf, so extract them from the pinned source
      # instead of vendoring a stale list here.
      installerSource = builtins.readFile "${inputs.determinate-nix-installer}/src/action/common/place_nix_configuration.rs";
      keyFromLine =
        line:
        let
          matches = builtins.match ".*\"(cache\\.flakehub\\.com-[^\"]+)\".*" line;
        in
        if matches == null then null else builtins.elemAt matches 0;
    in
    lib.filter (key: key != null) (map keyFromLine (lib.splitString "\n" installerSource));
in
lib.mkIf (config.host.realm == "home") {
  host.nix.caches.flakehub = {
    substituter = "https://cache.flakehub.com";
    trustedPublicKeys = flakehubCacheKeys;
    priorities = {
      lan = 30;
      wan = 10;
    };
  };

  host.nix.netrcMachines = {
    "flakehub.com" = {
      login = "flakehub";
      password = config.sops.placeholder."flakehub/token";
    };
    "api.flakehub.com" = {
      login = "flakehub";
      password = config.sops.placeholder."flakehub/token";
    };
    "cache.flakehub.com" = {
      login = "flakehub";
      password = config.sops.placeholder."flakehub/token";
    };
  };

  sops.secrets."flakehub/token" = { };
}
