{
  config,
  hostInventory,
  inputs,
  lib,
  ...
}:
let
  cfg = config.host.flakehubCache;
  realmFlakehubCache = hostInventory.realms.${config.host.realm}.services.flakehubCache or null;
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
{
  options.host.flakehubCache = {
    enable = lib.mkEnableOption "credentialed FlakeHub binary cache";

    url = lib.mkOption {
      type = with lib.types; nullOr str;
      default = if realmFlakehubCache == null then null else realmFlakehubCache.url;
      description = "FlakeHub binary cache URL provided by this host's realm.";
    };
  };

  config = lib.mkMerge [
    {
      host.flakehubCache.enable = lib.mkDefault (realmFlakehubCache != null);
      assertions = [
        {
          assertion = !cfg.enable || realmFlakehubCache != null;
          message = "realm '${config.host.realm}' does not define a FlakeHub cache";
        }
        {
          assertion = !cfg.enable || cfg.url != null;
          message = "host.flakehubCache.url must be set when the FlakeHub cache is enabled";
        }
      ];
    }
    (lib.mkIf cfg.enable {
      nix.settings = {
        netrc-file = config.sops.templates."flakehub-netrc".path;
        extra-substituters = [ cfg.url ];
        extra-trusted-public-keys = flakehubCacheKeys;
      };

      sops = {
        secrets."flakehub/token" = { };
        templates."flakehub-netrc" = {
          owner = "root";
          # macOS names gid 0 "wheel"; there is no root group.
          group = if config.host.isDarwin then "wheel" else "root";
          mode = "0400";
          content = ''
            machine flakehub.com login flakehub password ${config.sops.placeholder."flakehub/token"}
            machine api.flakehub.com login flakehub password ${config.sops.placeholder."flakehub/token"}
            machine cache.flakehub.com login flakehub password ${config.sops.placeholder."flakehub/token"}
          '';
        };
      };
    })
  ];
}
