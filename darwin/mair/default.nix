{
  config,
  fleetInventory,
  lib,
  pkgs,
  sshKeys,
  ...
}:
let
  username = config.host.username;
  hmConfig = config.home-manager.users.${username};
  passKey = fleetInventory.yubikeys.home.laptop.openpgp;
in
{
  system.stateVersion = 6;

  home-manager.users.${username} = {
    host.hm.pass.idleTimeout = 15 * 60;

    programs = {
      gpg.publicKeys = [
        {
          source = passKey.publicKey;
          trust = "ultimate";
        }
      ];

      # Prefer the Nano while the store retains the old recipient for Android.
      password-store.settings.PASSWORD_STORE_GPG_OPTS = "--try-secret-key ${passKey.fingerprint}";
    };

    host.hm.dev.agents.mcp.stdioServers.firefox-devtools = {
      instructions = ''
        Only use the Firefox DevTools MCP when the user explicitly requests browser
        interaction or browser-based debugging.
      '';
      command = lib.getExe pkgs.firefox-devtools-mcp;
      args = [
        "--firefox-path"
        "${hmConfig.home.homeDirectory}/Applications/Home Manager Apps/Firefox.app/Contents/MacOS/firefox"
        "--profile-path"
        "${hmConfig.xdg.dataHome}/firefox-devtools-mcp"
        "--accept-insecure-certs"
        "--viewport"
        "1440x1000"
      ];
    };
  };

  host = {
    hardware.isLaptop = true;
    nix.builderClient = { };
    network.interfaces.en0.kind = "wireless";
    security = {
      secrets.operator.ageIdentity = {
        backend = "secure-enclave";
        path = "/Users/${username}/.config/sops/age/mair-se.txt";
      };
    };
    remote-control = {
      client = {
        vnc = { };
        wayland = { };
        x11 = { };
      };
      server.vnc = { };
    };
    ssh = {
      credentials = {
        backend = "secretive";
        secretive.publicKey = sshKeys.keys.mairSecretive;
      };
      operator.authorizedKeys = sshKeys.operators.mair;
      tickets.issuer = {
        publicKey = sshKeys.ticketIssuers.mair;
        keyName = "fleet-user-ca.pub";
        useAgent = true;
      };
    };
  };

}
