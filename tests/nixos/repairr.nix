{ inputs, pkgs, ... }:
let
  inherit (pkgs) lib;
  mediaRoot = "/var/lib/repairr-test-media";
  queue =
    records:
    builtins.toJSON {
      page = 1;
      pageSize = 250;
      inherit records;
      totalRecords = builtins.length records;
    };
  album = {
    id = 42;
    title = "Unfinished album download";
    downloadId = "SABnzbd_nzo_album";
    protocol = "usenet";
    downloadClient = "SABnzbd";
    status = "downloading";
    size = 200;
    sizeleft = 100;
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
          locations."= /api/v1/queue".extraConfig = ''
            default_type application/json;
            return 200 '${queue [ album ]}';
          '';
          locations."= /api/v3/queue".extraConfig = ''
            default_type application/json;
            return 200 '${queue [ ]}';
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
    import json

    machine.start()
    machine.wait_for_unit("repairr.service")
    listing = "curl -fsS 'http://127.0.0.1:8790/api/jobs?service=lidarr&view=activity'"
    machine.wait_until_succeeds(listing + " | jq -e 'length == 1'")
    (album,) = json.loads(machine.succeed(listing))
    assert album["title"] == "Unfinished album download" and album["reasonCode"] == "queue_not_ready", album
    assert set(album["findings"]) == {
        "incomplete_download", "unsupported_queue_state", "missing_output_path",
        "missing_album_id", "missing_artist_id",
    }, album

    # The operator page gives the reason in plain language.
    page = machine.succeed("curl -fsS 'http://127.0.0.1:8790/activity?service=lidarr'")
    assert album["title"] in page and "Queue not ready" in page
    assert machine.succeed("stat -c %U /var/lib/repairr/jobs.db").strip() == "media-repair-worker"

    # With the queue offline, the restarted daemon can only show the stored job.
    machine.succeed("systemctl stop nginx.service")
    machine.succeed("systemctl restart repairr.service")
    machine.wait_until_succeeds("curl --fail http://127.0.0.1:8790/health")
    assert json.loads(machine.succeed(listing)) == [album]
    machine.fail("systemctl is-active radarr-repair-controller.timer")
    machine.fail("systemctl is-active lidarr-repair-controller.timer")
    machine.fail("systemctl is-active media-repair-worker.service")
  '';
}
