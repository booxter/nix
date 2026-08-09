{
  config,
  facts,
  lib,
  outputs,
  pkiPkgs,
  ...
}:
let
  cfg = config.services.unifi-sync;
  fleetServices = import ../_lib/fleet-web-services.nix {
    inherit config lib outputs;
  };
  webDnsRecords = import ../_lib/fleet-web-dns-records.nix {
    inherit fleetServices facts;
  };
  unifiSyncEnv = import ./unifi-sync-env.nix {
    inherit facts webDnsRecords;
    lanDomain = config.host.network.lanDomain;
  };
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
