{ pkgs }:
let
  serverName = "api.radarr.video";
  pki = import ../lib/tls-pki.nix { inherit pkgs serverName; };
  sonarrPki = import ../lib/tls-pki.nix {
    inherit pkgs;
    serverName = "*.sonarr.tv";
  };
  lidarrPki = import ../lib/tls-pki.nix {
    inherit pkgs;
    serverName = "api.lidarr.audio";
  };
in
{
  nodes.server = {
    environment.systemPackages = [ pkgs.ffmpeg-headless ];
    services.nginx = {
      enable = true;
      virtualHosts.${serverName} = {
        forceSSL = true;
        sslCertificate = "${pki}/server.crt";
        sslCertificateKey = "${pki}/server.key";
        locations."= /v1/movie/1".alias = ./radarr-metadata.json;
      };
      virtualHosts."skyhook.sonarr.tv" = {
        serverAliases = [ "services.sonarr.tv" ];
        forceSSL = true;
        sslCertificate = "${sonarrPki}/server.crt";
        sslCertificateKey = "${sonarrPki}/server.key";
        locations."= /v2/tvdb/shows/eng/1/official".alias = ./sonarr-metadata.json;
        locations."= /v1/dailyseries".return = "200 '${builtins.toJSON [ ]}'";
      };
      virtualHosts."api.lidarr.audio" = {
        forceSSL = true;
        sslCertificate = "${lidarrPki}/server.crt";
        sslCertificateKey = "${lidarrPki}/server.key";
        locations."= /api/v0.4/artist/11111111-1111-4111-8111-111111111111".alias = ./lidarr-artist.json;
        locations."= /api/v0.4/album/22222222-2222-4222-8222-222222222222".alias = ./lidarr-album.json;
      };
    };
  };
  nodes.client = { lib, nodes, ... }: {
    networking.hosts.${nodes.server.networking.primaryIPAddress} = [
      serverName
      "skyhook.sonarr.tv"
      "services.sonarr.tv"
      "api.lidarr.audio"
    ];
    security.pki.certificateFiles = [
      "${pki}/ca.crt"
      "${sonarrPki}/ca.crt"
      "${lidarrPki}/ca.crt"
    ];
    virtualisation.memorySize = 2048;
    environment.etc."arr-import.py".source = ./arr-import.py;
    services.radarr = {
      enable = true;
      package = pkgs.radarr;
      user = "importer";
      group = "media";
      settings.auth.apiKey = "reflink-test-api-key";
    };
    systemd.services.radarr.wantedBy = lib.mkForce [ ];
    services.sonarr = {
      enable = true;
      package = pkgs.sonarr;
      user = "importer";
      group = "media";
      settings.auth.apiKey = "reflink-test-api-key";
    };
    systemd.services.sonarr.wantedBy = lib.mkForce [ ];
    services.lidarr = {
      enable = true;
      package = pkgs.lidarr;
      user = "importer";
      group = "media";
      settings.auth.apiKey = "reflink-test-api-key";
    };
    systemd.services.lidarr.wantedBy = lib.mkForce [ ];
  };
}
