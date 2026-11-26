{ pkgs, ... }:
let
  inherit (pkgs) lib;
  downloads = "/var/lib/repairr-pipeline";
  release = "${downloads}/Example.Movie.2026";
  video = "${release}/movie.mkv";
  album = "${downloads}/Example.Album";
  fixtureURL = "http://127.0.0.1:7878";
  roots."root:downloads" = downloads;
  helper = import ../../nixos/_mixins/media-repair/helper.nix {
    inherit lib pkgs roots;
  };
  key = pkgs.writeText "repairr-test-key" "test-key";
  plannerSocket = "/run/repairr-planner/planner.sock";
  config = (pkgs.formats.json { }).generate "repairr-pipeline.json" {
    Roots = roots;
    Helper = helper;
    PlannerSocket = plannerSocket;
    Database = "/var/lib/repairr/jobs.db";
    MetricsFile = "/var/lib/repairr/metrics.prom";
    Listen = "127.0.0.1:8790";
    Radarr = {
      URL = fixtureURL;
      APIKeyFile = key;
      DisableFile = "/run/pause-radarr-repairs";
    };
    Lidarr = {
      URL = fixtureURL;
      APIKeyFile = key;
      DisableFile = "/run/pause-lidarr-repairs";
    };
    TransmissionURL = "${fixtureURL}/transmission/rpc";
    SABnzbdURL = fixtureURL;
    SABnzbdKeyFile = key;
    Timeouts = {
      RequestSeconds = 30;
      ProbeSeconds = 30;
      MediaSeconds = 60;
      PlanningSeconds = 30;
      ResponseGraceSeconds = 30;
    };
  };
  node = fixture: {
    environment.systemPackages = [
      pkgs.curl
      pkgs.repairr
    ];
    environment.etc."repairr.json".source = config;
    systemd.services.repairr-fixture = fixture // {
      wantedBy = [ "multi-user.target" ];
    };
    systemd.services.scripted-planner = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        RuntimeDirectory = "repairr-planner";
        ExecStart = "${lib.getExe pkgs.python3} ${./repairr-pipeline/planner.py} ${plannerSocket}";
      };
    };
    # The test starts the daemon with repairs paused so it can see the saved
    # decision before allowing the next step to inspect the source again.
    systemd.services.repairr.serviceConfig = {
      StateDirectory = "repairr";
      ExecStart = "${lib.getExe pkgs.repairr} --config /etc/repairr.json";
    };
  };
  ffmpeg = lib.getExe' pkgs.ffmpeg-headless "ffmpeg";
  movieNode = node {
    preStart = ''
      mkdir -p ${release}
      ${ffmpeg} -v error -y -f lavfi -i color=size=64x64:rate=1 -frames:v 1 -c:v mpeg4 ${video}
    '';
    serviceConfig = {
      RuntimeDirectory = "radarr-fixture";
      ExecStart = "${lib.getExe pkgs.python3} ${./repairr-pipeline/server.py} ${video}";
    };
  };
  albumNode = node {
    preStart = ''
      # On srvarr, storage provisioning creates the helper's workspace base.
      mkdir -p ${downloads}/.media-repair ${album}
      ${ffmpeg} -v error -y -f lavfi -i sine=frequency=440:duration=1 ${album}/01.flac
      ${ffmpeg} -v error -y -f lavfi -i sine=frequency=880:duration=1 ${album}/02.flac
    '';
    serviceConfig = {
      RuntimeDirectory = "lidarr-fixture";
      ExecStart = "${lib.getExe pkgs.python3} ${./repairr-pipeline/lidarr.py} ${album}";
    };
  };
in
pkgs.testers.runNixOSTest {
  name = "repairr-pipeline";
  nodes = {
    machine = movieNode;
    replaced = movieNode;
    missingMovie = movieNode;
    lostResponse = movieNode;
    albumImport = albumNode;
    unfinishedAlbum = albumNode;
  };
  testScript = builtins.readFile ./repairr-pipeline/test.py;
}
