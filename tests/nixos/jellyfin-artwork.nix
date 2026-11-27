{ inputs, pkgs }:
let
  jellyfin = inputs.nixpkgs.legacyPackages.${pkgs.stdenv.hostPlatform.system}.jellyfin;
  serverName = "api.themoviedb.org";
  pki = import ./lib/tls-pki.nix { inherit pkgs serverName; };
  fixtures =
    pkgs.runCommand "jellyfin-artwork-fixtures" { nativeBuildInputs = [ pkgs.ffmpeg-headless ]; }
      ''
        mkdir "$out"
        ffmpeg -v error -f lavfi -i color=c=blue:s=64x64:r=1 -t 2 -c:v mpeg4 "$out/movie.mkv"
        ffmpeg -v error -f lavfi -i color=c=red:s=64x96 -frames:v 1 -threads 1 "$out/poster.png"
        ffmpeg -v error -f lavfi -i color=c=green:s=96x64 -frames:v 1 -threads 1 "$out/backdrop.png"
        ffmpeg -v error -f lavfi -i color=c=yellow:s=64x96 -frames:v 1 -threads 1 "$out/custom.png"
      '';
in
pkgs.testers.runNixOSTest {
  name = "jellyfin-artwork";

  nodes.machine = {
    virtualisation = {
      cores = 4;
      diskSize = 8192;
      memorySize = 3072;
    };
    networking.hosts."127.0.0.1" = [ serverName ];
    security.pki.certificateFiles = [ "${pki}/ca.crt" ];
    environment.systemPackages = [
      pkgs.curl
      pkgs.python3
    ];
    environment.etc."jellyfin-artwork-probe.py".source = ./jellyfin-artwork/probe.py;

    services.jellyfin = {
      enable = true;
      package = jellyfin;
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

    systemd.services.jellyfin-artwork-fixture = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 /etc/jellyfin-artwork-probe.py serve ${fixtures}";
    };
    systemd.tmpfiles.rules = [ "d /srv/movies 0777 root root -" ];
  };

  testScript = ''
    start_all()
    machine.wait_for_unit("nginx.service")
    machine.wait_for_unit("jellyfin-artwork-fixture.service")
    machine.wait_for_open_port(8096)
    machine.wait_until_succeeds("curl -fsS http://127.0.0.1:8096/health | grep -qx Healthy")

    with subtest("replacement movies recover missing artwork and preserve existing posters"):
        try:
            print(machine.succeed("python3 /etc/jellyfin-artwork-probe.py check ${fixtures}", timeout=240))
        except Exception:
            print(machine.succeed("journalctl -u jellyfin -u jellyfin-artwork-fixture -u nginx -n 200 --no-pager"))
            raise
  '';
}
