{ pkgs, ... }:
let
  serverName = "skyhook.sonarr.tv";
  pki = import ./lib/tls-pki.nix {
    inherit pkgs;
    serverName = "*.sonarr.tv";
  };
  probe = ./sonarr-refresh-race/probe.py;
  fixture = ./nfs-btrfs-reflink/sonarr-metadata.json;
in
pkgs.testers.runNixOSTest {
  name = "sonarr-refresh-race";

  nodes.machine = {
    virtualisation.memorySize = 2048;
    virtualisation.cores = 2;
    networking.hosts."127.0.0.1" = [
      serverName
      "services.sonarr.tv"
    ];
    security.pki.certificateFiles = [ "${pki}/ca.crt" ];
    services.nginx = {
      enable = true;
      virtualHosts.${serverName} = {
        serverAliases = [ "services.sonarr.tv" ];
        forceSSL = true;
        sslCertificate = "${pki}/server.crt";
        sslCertificateKey = "${pki}/server.key";
        locations."/".proxyPass = "http://127.0.0.1:18080";
      };
    };
    systemd.services.test-metadata = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${pkgs.python3}/bin/python ${probe} metadata ${fixture}";
    };
    services.sonarr = {
      enable = true;
      package = pkgs.sonarr;
      settings.auth.apiKey = "test-sonarr-api-key";
    };
    systemd.tmpfiles.rules = [ "d /srv/series 0755 sonarr sonarr -" ];
  };

  testScript = ''
    machine.start()
    machine.wait_for_open_port(18080)
    machine.wait_for_unit("nginx.service")
    machine.wait_for_open_port(8989)
    try:
        print(machine.succeed("${pkgs.python3}/bin/python ${probe} check", timeout=240))
    except Exception:
        print(machine.succeed("journalctl -u sonarr -u test-metadata -n 150 --no-pager"))
        raise
  '';
}
