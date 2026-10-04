{ inputs, pkgs, ... }:
let
  inherit (pkgs) lib;
  mediaRoot = "/var/lib/repairr-test-media";
  emptyQueue = builtins.toJSON {
    page = 1;
    pageSize = 250;
    records = [ ];
    totalRecords = 0;
  };
in
pkgs.testers.runNixOSTest {
  name = "repairr";
  nodes.machine = {
    imports = [
      inputs.sops-nix.nixosModules.sops
      ../../nixos/_mixins/downloads/default.nix
      ../../nixos/_mixins/media-repair
      ../../nixos/_mixins/web/options.nix
      ./lib/sops.nix
    ];
    options.host.network.lanDomain = lib.mkOption {
      type = lib.types.str;
      default = "test.invalid";
    };
    options.host.storage.claims = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
    };
    config = {
      host.mediaRepair = {
        enable = true;
        roots."root:downloads" = mediaRoot;
      };
      host.downloads.clients = {
        transmission = {
          kind = "torrent";
          implementation = "transmission";
          endpoint = "http://127.0.0.1:9091/transmission/rpc";
          authentication.type = "none";
        };
        sabnzbd = {
          kind = "usenet";
          implementation = "sabnzbd";
          endpoint = "http://127.0.0.1:8080";
          authentication = {
            type = "api-key";
            secret = "sabnzbd/apiKey";
          };
        };
      };
      testSupport.sops.values = {
        "radarr/apiKey" = "test-radarr-key";
        "lidarr/apiKey" = "test-lidarr-key";
        "sabnzbd/apiKey" = "test-sabnzbd-key";
        "radarr-repair/openrouter-api-key" = "test-planner-key";
      };
      sops.secrets."radarr/apiKey" = { };
      sops.secrets."lidarr/apiKey" = { };
      sops.secrets."sabnzbd/apiKey" = { };
      services.radarr.settings.server.port = 7878;
      services.lidarr.settings.server.port = 8686;
      users.groups.media = { };
      systemd.tmpfiles.rules = [ "d ${mediaRoot} 0750 media-repair-worker media -" ];
      systemd.services.repairr.after = [ "nginx.service" ];
      services.nginx = {
        enable = true;
        virtualHosts.servarr-test = {
          listen = [
            {
              addr = "127.0.0.1";
              port = 7878;
            }
            {
              addr = "127.0.0.1";
              port = 8686;
            }
          ];
          locations."/".extraConfig = ''
            default_type application/json;
            return 200 '${emptyQueue}';
          '';
        };
      };
      environment.systemPackages = [
        pkgs.curl
        pkgs.jq
      ];
    };
  };
  testScript = ''
    machine.start()
    machine.wait_for_unit("repairr.service")
    machine.wait_until_succeeds("curl --fail http://127.0.0.1:8790/health")
    page = machine.succeed("curl --fail http://127.0.0.1:8790/lidarr")
    assert "Repairr" in page
    assert machine.succeed("stat -c %U /var/lib/repairr/jobs.db").strip() == "media-repair-worker"

    # A daemon restart must leave the operator inbox available.
    machine.succeed("systemctl restart repairr.service")
    machine.wait_until_succeeds("curl --fail http://127.0.0.1:8790/health")
    assert "Repairr" in machine.succeed("curl --fail http://127.0.0.1:8790/lidarr")
    machine.fail("systemctl is-active radarr-repair-controller.timer")
    machine.fail("systemctl is-active lidarr-repair-controller.timer")
    machine.fail("systemctl is-active media-repair-worker.service")
  '';
}
