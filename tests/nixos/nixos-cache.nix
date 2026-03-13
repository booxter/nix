{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "nixos-cache";

  nodes.cache = { lib, pkgs, ... }: {
    imports = [
      ../../nixos/cachevm/default.nix
    ];

    # Test-only overrides: avoid external dependencies from the production host.
    fileSystems."/cache" = lib.mkForce {
      device = "tmpfs";
      fsType = "tmpfs";
      options = [ "mode=0755" ];
    };
    services.atticd.environmentFile = lib.mkForce "/run/atticd.env";
    systemd.services.atticd.preStart = lib.mkBefore ''
      umask 077
      printf 'ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64=%s\n' \
        "$(${pkgs.openssl}/bin/openssl genrsa -traditional 2048 | ${pkgs.coreutils}/bin/base64 -w0)" \
        > /run/atticd.env
    '';

    environment.systemPackages = [ pkgs.curl ];
  };

  testScript = ''
    start_all()

    cache.wait_for_unit("atticd.service")
    cache.succeed("systemctl is-active --quiet atticd.service")
    cache.wait_for_open_port(8080)
    cache.wait_until_succeeds(
      "code=$(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/); test \"$code\" != 000"
    )
  '';
}
