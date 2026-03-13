{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "nixos-cache";

  nodes.cache =
    { lib, pkgs, ... }:
    {
      imports = [
        ../../nixos/cachevm/default.nix
      ];

      # Test-only overrides: avoid external dependencies from the production host.
      fileSystems."/cache" = lib.mkForce {
        device = "tmpfs";
        fsType = "tmpfs";
        options = [ "mode=0755" ];
      };
      systemd.tmpfiles.rules = [
        "d /cache 0755 root root -"
      ];
      environment.etc."atticd.env".source = ./fixtures/atticd.env;

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
