{
  config,
  lib,
  pkgs,
  ...
}:
let
  username = config.host.username;
  hmConfig = config.home-manager.users.${username};
  readPublicKey = import ../../common/_lib/read-public-key.nix { inherit lib; };
in
{
  system.stateVersion = 6;

  imports = [
    ./opencode.nix
  ];

  home-manager.users.${username}.host.hm.dev.codex.mcp.stdioServers.firefox-devtools = {
    instructions = ''
      Only use the Firefox DevTools MCP when the user explicitly requests browser
      interaction or browser-based debugging.
    '';
    command = lib.getExe pkgs.firefox-devtools-mcp;
    args = [
      "--profile-path"
      "${hmConfig.xdg.dataHome}/firefox-devtools-mcp"
      "--accept-insecure-certs"
      "--viewport"
      "1440x1000"
    ];
  };

  host = {
    hardware.isLaptop = true;
    network.interfaces.en0.kind = "wireless";
    security = {
      secrets.operator.ageIdentity = {
        backend = "secure-enclave";
        path = "/Users/${username}/.config/sops/age/mair-se.txt";
      };
    };
    userEnvironment = {
      preset = "personal";
      roles = {
        developer.enable = true;
        workstation.enable = true;
      };
    };
    remote-control = {
      client = {
        vnc.enable = true;
        wayland.enable = true;
        x11.enable = true;
      };
      server.vnc.enable = true;
    };
    ssh = {
      credentials = {
        backend = "secretive";
        secretive.publicKey = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBHMpzrKs1o9ek9+rZw3O8y7tzedq+iMObfvGA1xVS9uKX1cdSp7rnWyq83Y2hsfPI+J2quB42JFVUzCxn4NVfvM= ihar.hrachyshka@gmail.com";
      };
      operator.authorizedKeys = [
        (readPublicKey ../../common/_mixins/ssh/public-keys/mair.pub)
        (readPublicKey ../../common/_mixins/ssh/public-keys/mair-secretive.pub)
      ];
      tickets.issuer = {
        publicKey = readPublicKey ../../common/_mixins/ssh/public-keys/fleet-user-ca.pub;
        keyName = "fleet-user-ca.pub";
        useAgent = true;
      };
    };
    wireguard.client = {
      enable = true;
      network = "home";
      address = "10.83.0.10";
      publicKey = readPublicKey ./wireguard.pub;
      privateKeySecret = "wireguard/gw/privateKey";
    };
  };

}
