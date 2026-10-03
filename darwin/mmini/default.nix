{
  config,
  lib,
  pkgs,
  ...
}:
let
  readPublicKey = import ../../common/_lib/read-public-key.nix { inherit lib; };
in
{
  system.stateVersion = 5;

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
    operator.authorizedKeys = [
      (readPublicKey ../../common/_mixins/ssh/public-keys/mmini.pub)
      (readPublicKey ../../common/_mixins/ssh/public-keys/yubikey.pub)
    ];
    tickets.issuer = {
      publicKey = readPublicKey ../../common/_mixins/ssh/public-keys/yubikey.pub;
      keyName = "id_ed25519_sk_rk";
      useAgent = false;
    };
  };

  host.security = {
    secrets.operator.ageIdentity = {
      backend = "yubikey";
      path = "/Users/${config.host.username}/.config/sops/age/yubi-nix.txt";
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
