{ config, lib, ... }:
let
  readPublicKey = import ../../common/_lib/read-public-key.nix { inherit lib; };
in
{
  system.stateVersion = 5;

  home-manager.users.${config.host.username}.programs.firefox.configPath =
    "Library/Application Support/org.nixos.firefox";

  imports = [
    ./cache-warmer.nix
  ];

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
}
