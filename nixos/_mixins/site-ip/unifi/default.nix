{
  config,
  lib,
  outputs,
  pkgs,
  ...
}:
let
  unifiPkgs = import ./pkgs pkgs;
  cfg = config.services.unifi-sync;
  controller = config.host.site.lan.ipController;
  fleetServices = import ../../../_lib/fleet-web-services.nix {
    inherit config lib outputs;
  };
  fleetNetwork = import ../../../_lib/fleet-host-network.nix { inherit config outputs; };
  webDnsRecords = import ../../../_lib/fleet-web-dns-records.nix {
    inherit fleetServices;
    addressFor = fleetNetwork.addressFor;
  };
  wireguardStaticRoutes = lib.mapAttrsToList (name: network: {
    destination = network.cidr;
    nextHopHost = network.server.host;
    distance = 1;
    name = "wg-${name}";
  }) config.host.wireguard.networks;
  unifiSyncEnv = import ./environment.nix {
    inherit webDnsRecords;
    addressFor = fleetNetwork.addressFor;
    baseUrl = controller.endpoint;
    lan = config.host.site.lan;
    lanDomain = config.host.network.lanDomain;
    reservations = config.host.network.ipReservations;
    site = controller.site;
    staticRoutes = config.host.site.lan.staticRoutes ++ wireguardStaticRoutes;
  };
in
{
  imports = [
    ./service.nix
    ./wireguard-dns-sync.nix
  ];

  config = lib.mkIf (config.host.network.ipController == "unifi") {
    services.unifi-sync = {
      enable = true;
      package = unifiPkgs.unifi-sync;
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
  };
}
