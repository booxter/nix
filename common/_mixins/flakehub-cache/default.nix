{
  config,
  hostInventory,
  inputs,
  lib,
  pkgs,
  hostname,
  hostSpecName ? hostname,
  ...
}:
let
  hostSecretName =
    if builtins.hasAttr hostSpecName hostInventory.nixosHostSpecsByName then hostSpecName else hostname;
  hostSecretFile = ../../../secrets/${hostSecretName}.yaml;
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
lib.mkMerge [
  {
    nix.settings = {
      netrc-file = config.sops.templates."flakehub-netrc".path;
      extra-substituters = [ hostInventory.site.nixCaches.flakehub.url ];
      extra-trusted-public-keys = flakehubCacheKeys;
    };

    sops = {
      defaultSopsFile = hostSecretFile;
    }
    // {
      secrets = {
        "flakehub/token" = { };
      };
      templates."flakehub-netrc" = {
        owner = "root";
        # macOS names gid 0 "wheel"; there is no root group.
        group = if pkgs.stdenv.hostPlatform.isDarwin then "wheel" else "root";
        mode = "0400";
        content = ''
          machine flakehub.com login flakehub password ${config.sops.placeholder."flakehub/token"}
          machine api.flakehub.com login flakehub password ${config.sops.placeholder."flakehub/token"}
          machine cache.flakehub.com login flakehub password ${config.sops.placeholder."flakehub/token"}
        '';
      };
    };
  }
]
