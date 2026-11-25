{ pkgs, ... }:
let
  serverName = "api.radarr.video";
  pki = import ./lib/tls-pki.nix { inherit pkgs serverName; };
  probe = ./radarr-refresh-race/probe.py;
  metadataFixture = ./nfs-btrfs-reflink/radarr-metadata.json;
in
pkgs.testers.runNixOSTest {
  name = "radarr-refresh-race";

  nodes.machine = {
    virtualisation = {
      cores = 4;
      memorySize = 3072;
    };
    networking.hosts."127.0.0.1" = [ serverName ];
    security.pki.certificateFiles = [ "${pki}/ca.crt" ];

    environment.systemPackages = [ pkgs.python3 ];
    environment.etc = {
      "radarr-refresh-probe.py".source = probe;
      "radarr-metadata.json".source = metadataFixture;
    };
    services.nginx = {
      enable = true;
      virtualHosts.${serverName} = {
        forceSSL = true;
        sslCertificate = "${pki}/server.crt";
        sslCertificateKey = "${pki}/server.key";
        locations."/".proxyPass = "http://127.0.0.1:18080";
      };
    };

    services.radarr = {
      enable = true;
      package = pkgs.radarr;
      settings.auth.apiKey = "radarr-refresh-test-key";
    };
    systemd.tmpfiles.rules = [ "d /srv/movies 0755 radarr radarr -" ];
  };

  testScript = builtins.readFile ./radarr-refresh-race/test.py;
}
