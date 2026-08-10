{
  config,
  facts,
  lib,
  outputs,
  pkgs,
  ...
}:
let
  unifiPkgs = import ./pkgs pkgs;
  cfg = config.services.unifi-sync;
  controller = config.host.network.ipController;
  fleetServices = import ../../../_lib/fleet-web-services.nix {
    inherit config lib outputs;
  };
  fleetNetwork = import ../../../_lib/fleet-host-network.nix { inherit config outputs; };
  webDnsRecords = import ../../../_lib/fleet-web-dns-records.nix {
    inherit fleetServices;
    addressFor = fleetNetwork.addressFor;
  };
  unifiSyncEnv = import ./environment.nix {
    inherit facts webDnsRecords;
    addressFor = fleetNetwork.addressFor;
    lanDomain = config.host.network.lanDomain;
    reservations = config.host.network.ipController.reservations;
  };
in
{
  imports = [
    ./service.nix
    ./wireguard-dns-sync.nix
  ];

  config = lib.mkIf (controller.enable && controller.flavor == "unifi") {
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
