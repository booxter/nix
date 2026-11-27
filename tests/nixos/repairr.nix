{ inputs, pkgs, ... }:
let
  inherit (pkgs) lib;
  mediaRoot = "/var/lib/repairr-test-media";
  movieFixture = import ./repairr-pipeline/movie-fixture.nix {
    inherit pkgs;
    video = "${mediaRoot}/Example.Movie.2026/movie.mkv";
  };
  fixtureURL = "http://127.0.0.1:7878";
  loopback = port: [
    {
      addr = "127.0.0.1";
      inherit port;
    }
  ];
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
      services.radarr.settings.server.port = 7879;
      services.lidarr.settings.server.port = 8686;
      users.groups.media = { };
      # Repairr needs group access to read a movie owned by another user.
      systemd.tmpfiles.rules = [ "d ${mediaRoot} 2750 root media -" ];
      systemd.services.repairr-fixture = lib.mkMerge [
        movieFixture
        {
          serviceConfig.UMask = "0027";
          postStart = "${pkgs.curl}/bin/curl -fsS --retry-connrefused --retry 10 ${fixtureURL}/fixture/imports";
        }
      ];
      systemd.services.repairr = {
        requires = [ "repairr-fixture.service" ];
        after = [
          "repairr-fixture.service"
          "nginx.service"
        ];
      };
      # Use the module's planner socket, service user and sandbox with a local decision.
      systemd.services.media-repair-planner.serviceConfig.ExecStart =
        lib.mkForce "${lib.getExe pkgs.python3} ${./repairr-pipeline/planner.py}";
      services.nginx = {
        enable = true;
        virtualHosts.lidarr = {
          listen = loopback 8686;
          locations."= /api/v1/queue".extraConfig = ''
            if ($http_x_api_key != "test-lidarr-key") { return 403; }
            default_type application/json;
            return 200 '${queue [ album ]}';
          '';
        };
        virtualHosts.radarr = {
          listen = loopback 7879;
          locations."/api/v3/" = {
            proxyPass = fixtureURL;
            extraConfig = ''if ($http_x_api_key != "test-radarr-key") { return 403; }'';
          };
        };
        virtualHosts.sabnzbd = {
          listen = loopback 8080;
          locations."= /api" = {
            proxyPass = fixtureURL;
            extraConfig = ''if ($arg_apikey != "test-sabnzbd-key") { return 403; }'';
          };
        };
      };
      environment.systemPackages = [
        pkgs.curl
        pkgs.jq
      ];
    };
  };
  testScript = builtins.readFile ./repairr.py;
}
