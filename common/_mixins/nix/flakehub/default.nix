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
  nix.settings.netrc-file = config.sops.templates."flakehub-netrc".path;

  host.nix.caches.flakehub = {
    substituter = "https://cache.flakehub.com";
    trustedPublicKeys = flakehubCacheKeys;
    priorities = {
      lan = 30;
      wan = 10;
    };
  };

  sops = {
    secrets."flakehub/token" = { };
    templates."flakehub-netrc" = {
      owner = "root";
      # macOS names gid 0 "wheel"; there is no root group.
      group = if config.nixpkgs.hostPlatform.isDarwin then "wheel" else "root";
      mode = "0400";
      content = ''
        machine flakehub.com login flakehub password ${config.sops.placeholder."flakehub/token"}
        machine api.flakehub.com login flakehub password ${config.sops.placeholder."flakehub/token"}
        machine cache.flakehub.com login flakehub password ${config.sops.placeholder."flakehub/token"}
      '';
    };
  };
}
