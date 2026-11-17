{ pkgs }:
let
  serverName = "api.radarr.video";
  pki = import ../lib/tls-pki.nix { inherit pkgs serverName; };
  sonarrPki = import ../lib/tls-pki.nix {
    inherit pkgs;
    serverName = "*.sonarr.tv";
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
        locations."= /v1/tvdb/shows/en/1".alias = ./sonarr-metadata.json;
        locations."= /v1/dailyseries".return = "200 '${builtins.toJSON [ ]}'";
      };
    };
  };
  nodes.client = { lib, nodes, ... }: {
    networking.hosts.${nodes.server.networking.primaryIPAddress} = [
      serverName
      "skyhook.sonarr.tv"
      "services.sonarr.tv"
    ];
    security.pki.certificateFiles = [
      "${pki}/ca.crt"
      "${sonarrPki}/ca.crt"
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
  };
}
