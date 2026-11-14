{
  config,
  fleetInventory,
  lib,
  pkgs,
  sshKeys,
  ...
}:
{
  imports = [ ./vm-runner.nix ];

  system.stateVersion = 5;

  home-manager.users.${config.host.username}.host.hm.pass.yubikey = "main";

  host.attic.ci.enable = true;

  host.nix.builderClient = { };

  host.network.interfaces.en0 = { };

  host.remote-control = {
    client = {
      vnc = { };
      x11 = { };
    };
    server.vnc = { };
  };

  host.ssh = {
    credentials.backend = "yubikey";
    operator.authorizedKeys = sshKeys.operators.mmini;
    tickets.issuer = {
      publicKey = sshKeys.ticketIssuers.mmini;
      keyName = "id_ed25519_sk_rk";
      useAgent = false;
    };
  };

  host.security = {
    secrets.operator.ageIdentity = {
      backend = "yubikey";
      path = "${fleetInventory.yubikeys.home.main.ageIdentity}";
    };
  };

  services.github-runners.mmini-ci = {
    enable = true;
    url = "https://github.com/booxter/nix";
    tokenFile = config.sops.secrets."github/actions_runner/token".path;
    name = "mmini-ci";
    ephemeral = true;
    extraLabels = [ "nix-ci-darwin" ];
    noDefaultLabels = true;
    replace = true;
    extraEnvironment.CI_ATTIC_CONFIG = config.sops.templates."attic-ci.toml".path;
    serviceOverrides = {
      # Restart after deleted-registration errors so ephemeral startup registers again.
      KeepAlive = lib.mkForce true;
    };
    extraPackages = with pkgs; [
      findutils
      gawk
      gnumake
      gnugrep
      jq
    ];
  };

  host.launchd.logging.locations.github-runner = {
    directory = "/var/log/github-runners/mmini-ci";
    collect = true;
    scope = "system";
  };

  sops.secrets."github/actions_runner/token" = {
    mode = "0400";
    owner = "_github-runner";
  };
}
