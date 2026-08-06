{
  config,
  hostInventory,
  pkiPkgs,
  ...
}:
let
  cfg = config.services.unifi-sync;
  unifiSyncEnv = import ./unifi-sync-env.nix { inherit hostInventory; };
in
{
  services.unifi-sync = {
    enable = true;
    package = pkiPkgs.unifi-sync;
    environment = unifiSyncEnv.environment;
    environmentFile = config.sops.templates."unifi-sync.env".path;
  };

  sops.secrets.unifiApiKey = {
    key = "unifi/api_key";
    owner = cfg.user;
    group = cfg.group;
    mode = "0400";
    restartUnits = [ "unifi-sync.service" ];
  };

  sops.templates."unifi-sync.env" = {
    owner = cfg.user;
    group = cfg.group;
    mode = "0400";
    content = ''
      UNIFI_API_KEY=${config.sops.placeholder.unifiApiKey}
    '';
    restartUnits = [ "unifi-sync.service" ];
  };

  systemd.services.unifi-sync = {
    wants = [
      "sops-install-secrets.service"
    ];
    after = [
      "sops-install-secrets.service"
    ];
  };
}
