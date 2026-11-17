{ pkgs }:
let
  serverName = "api.radarr.video";
  pki = import ../lib/tls-pki.nix { inherit pkgs serverName; };
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
    };
  };
  nodes.client = { lib, nodes, ... }: {
    networking.hosts.${nodes.server.networking.primaryIPAddress} = [ serverName ];
    security.pki.certificateFiles = [ "${pki}/ca.crt" ];
    environment.etc."arr-import.py".source = ./arr-import.py;
    services.radarr = {
      enable = true;
      package = pkgs.radarr;
      user = "importer";
      group = "media";
      settings.auth.apiKey = "reflink-test-api-key";
    };
    systemd.services.radarr.wantedBy = lib.mkForce [ ];
  };
}
