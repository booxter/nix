{ inputs, pkgs, ... }:
let
  fixtures = ./oauth2-proxy-gate;
  serverName = "test.example.invalid";
  testPki = import ./lib/tls-pki.nix { inherit pkgs serverName; };
in
pkgs.testers.runNixOSTest {
  name = "oauth2-proxy-gate";

  containers.machine =
    { lib, ... }:
    {
      imports = [
        inputs.sops-nix.nixosModules.sops
        ../../nixos/_mixins/sso/oauth2-proxy-gate
        ../../nixos/_mixins/web/internal-https
        ./lib/sops.nix
      ];

      config = {
        host.pki.authority = lib.mkForce {
          hostName = "test-authority";
          rootCaCertificate = "${testPki}/ca.crt";
        };

        host.network.lanDomain = "example.invalid";
        host.sso.providerHost = "provider";

        sops.placeholder.oauth2-proxy-gate-test-client-secret = "test-client-secret";

        host.web.services.test = {
          upstream = "http://127.0.0.1:9000";
          internal = {
            inherit serverName;
            clientAuth = "none";
          };
        };

        host.sso.oauth2ProxyGates.test = {
          displayName = "Test";
          externalOrigin = "https://test.example.invalid";
          groupClaim = "groups";
          allowedGroups = [ "test-users" ];
          internalHttpsServiceNames = [ "test" ];
        };

        testSupport.sops.sources = {
          internal-https-test-server-crt = "${testPki}/server.crt";
          internal-https-test-server-key = "${testPki}/server.key";
        };

        # The test supplies a deterministic fake auth endpoint instead of
        # starting oauth2-proxy and provisioning its credentials.
        systemd.services.oauth2-proxy-test.wantedBy = lib.mkForce [ ];

        systemd.services.fake-oauth2-proxy = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig.ExecStart = "${pkgs.python3}/bin/python ${fixtures}/fake-oauth2-proxy.py";
        };

        systemd.services.fake-oauth2-backend = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig.ExecStart = "${pkgs.python3}/bin/python ${fixtures}/fake-backend.py";
        };

        environment.systemPackages = [ pkgs.curl ];
      };
    };

  testScript = ''
    SERVER_NAME = ${builtins.toJSON serverName}
    TEST_PKI = ${builtins.toJSON "${testPki}"}
  ''
  + builtins.readFile "${fixtures}/test.py";
}
