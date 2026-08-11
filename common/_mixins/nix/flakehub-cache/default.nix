{
  config,
  inputs,
  lib,
  ...
}:
let
  cfg = config.host.nix.flakehubCache;
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
  options.host.nix.flakehubCache = {
    enable = lib.mkEnableOption "credentialed FlakeHub binary cache";

    url = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "https://cache.flakehub.com";
      description = "FlakeHub binary cache URL.";
    };
  };

  config = lib.mkMerge [
    {
      host.nix.flakehubCache.enable = lib.mkDefault (config.host.realm == "home");
    }
    (lib.mkIf cfg.enable {
      nix.settings = {
        netrc-file = config.sops.templates."flakehub-netrc".path;
      };

      host.nix.cacheContributions.flakehub = {
        substituter = cfg.url;
        trustedPublicKeys = flakehubCacheKeys;
        priorities = {
          tunnelInactive = 30;
          tunnelActive = 10;
        };
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
