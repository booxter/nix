{ pkgs, ... }:
let
  serverName = "api.lidarr.audio";
  pki = import ./lib/tls-pki.nix { inherit pkgs serverName; };
  probe = ./lidarr-refresh-race/probe.py;
in
pkgs.testers.runNixOSTest {
  name = "lidarr-refresh-race";

  nodes.machine = {
    virtualisation = {
      cores = 4;
      memorySize = 3072;
    };
    networking.hosts."127.0.0.1" = [ serverName ];
    security.pki.certificateFiles = [ "${pki}/ca.crt" ];
    environment.etc = {
      "lidarr-artist.json".source = ./nfs-btrfs-reflink/lidarr-artist.json;
      "lidarr-album.json".source = ./nfs-btrfs-reflink/lidarr-album.json;
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
    services.lidarr = {
      enable = true;
      package = pkgs.lidarr;
      settings.auth.apiKey = "lidarr-refresh-test-key";
    };
    systemd.tmpfiles.rules = [ "d /srv/music 0755 lidarr lidarr -" ];
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("nginx.service")
    machine.wait_for_open_port(8686)
    try:
        print(machine.succeed("${pkgs.python3}/bin/python ${probe}", timeout=180))
        # Artist refresh catches album failures and can still complete successfully.
        machine.fail(
            "journalctl -u lidarr --no-pager "
            "| grep -E 'UNIQUE constraint failed: (AlbumReleases|Tracks)'"
        )
    except Exception:
        print(machine.succeed("journalctl -u lidarr -u nginx -n 200 --no-pager"))
        raise
  '';
}
