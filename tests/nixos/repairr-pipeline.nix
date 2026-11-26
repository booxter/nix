{ pkgs, ... }:
let
  inherit (pkgs) lib;
  downloads = "/var/lib/repairr-pipeline";
  release = "${downloads}/Example.Movie.2026";
  video = "${release}/movie.mkv";
  fixtureURL = "http://127.0.0.1:7878";
  roots."root:downloads" = downloads;
  helper = import ../../nixos/_mixins/media-repair/helper.nix {
    inherit lib pkgs roots;
  };
  key = pkgs.writeText "repairr-test-key" "test-key";
  config = (pkgs.formats.json { }).generate "repairr-pipeline.json" {
    Roots = roots;
    Helper = helper;
    Radarr = {
      URL = fixtureURL;
      APIKeyFile = key;
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
in
pkgs.testers.runNixOSTest {
  name = "repairr-pipeline";
  nodes.machine = {
    environment.systemPackages = [ pkgs.repairr ];
    environment.etc."repairr.json".source = config;
    systemd.services.repairr-fixture = {
      wantedBy = [ "multi-user.target" ];
      # The APIs are fixtures. Repairr's production helper probes this real file in the VM.
      preStart = ''
        mkdir -p ${release}
        ${lib.getExe' pkgs.ffmpeg-headless "ffmpeg"} -v error -y \
          -f lavfi -i color=size=64x64:rate=1 -frames:v 1 -c:v mpeg4 ${video}
      '';
      serviceConfig.ExecStart = "${lib.getExe pkgs.python3} ${./repairr-pipeline/server.py} ${video}";
    };
  };
  testScript = builtins.readFile ./repairr-pipeline/test.py;
}
