{ inputs, pkgs, ... }:
let
  inherit (pkgs) lib;
  mediaRoot = "/var/lib/repairr-test-media";
  album = "${mediaRoot}/Example.Album";
  albumFixture = import ./repairr-pipeline/album-fixture.nix {
    inherit pkgs album;
    port = 8687;
  };
  movieFixture = import ./repairr-pipeline/movie-fixture.nix {
    inherit pkgs;
    video = "${mediaRoot}/Example.Movie.2026/movie.mkv";
  };
  radarrURL = "http://127.0.0.1:7878";
  lidarrURL = "http://127.0.0.1:8687";
  # The first queue poll should see both fixtures ready to serve.
  pendingImportFixture = url: {
    environment.TRACKED_DOWNLOAD_STATE = "importPending";
    serviceConfig.UMask = "0027";
    postStart = "${pkgs.curl}/bin/curl -fsS --retry-connrefused --retry 10 ${url}/fixture/imports";
  };
  loopback = port: [
    {
      addr = "127.0.0.1";
      inherit port;
    }
  ];
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
      users.users.lidarr-fixture = {
        isSystemUser = true;
        group = "media";
      };
      # As on srvarr, Repairr can read the downloads and owns the workspace.
      systemd.tmpfiles.rules = [
        "d ${mediaRoot} 2750 root media -"
        "d ${album} 2750 lidarr-fixture media -"
        "d ${mediaRoot}/.media-repair 2750 media-repair-worker media -"
        # The test restores the planner after both apps report their first failure.
        "f /run/repairr-planner-unavailable - - - -"
      ];
      systemd.services.radarr-fixture = lib.mkMerge [
        movieFixture
        (pendingImportFixture radarrURL)
      ];
      systemd.services.lidarr-fixture = lib.mkMerge [
        albumFixture
        (pendingImportFixture lidarrURL)
        { serviceConfig.User = "lidarr-fixture"; }
      ];
      systemd.services.repairr = {
        requires = [
          "radarr-fixture.service"
          "lidarr-fixture.service"
        ];
        after = [
          "radarr-fixture.service"
          "lidarr-fixture.service"
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
          locations."/api/v1/" = {
            proxyPass = lidarrURL;
            extraConfig = ''if ($http_x_api_key != "test-lidarr-key") { return 403; }'';
          };
        };
        virtualHosts.radarr = {
          listen = loopback 7879;
          locations."/api/v3/" = {
            proxyPass = radarrURL;
            extraConfig = ''if ($http_x_api_key != "test-radarr-key") { return 403; }'';
          };
        };
        virtualHosts.sabnzbd = {
          listen = loopback 8080;
          locations."= /api" = {
            proxyPass = radarrURL;
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
