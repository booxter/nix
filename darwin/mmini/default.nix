{ config, lib, ... }:
let
  readPublicKey = import ../../common/_lib/read-public-key.nix { inherit lib; };
in
{
  system.stateVersion = 5;

  host.nix.builder.enable = true;

  host.nix.cacheWarmer.enable = true;

  host.userEnvironment = {
    preset = "personal";
    roles = {
      developer.enable = true;
      workstation.enable = true;
    };
  };

  host.network.interfaces.en0.kind = "ethernet";

  host.remote-control = {
    client.enable = true;
    server.vnc.enable = true;
  };

  host.ssh = {
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

  host.ups.client.server = "frame";

  host.security = {
    smartCard.enable = true;
    secrets.operator.ageIdentity = {
      backend = "yubikey";
      path = "/Users/${config.host.username}/.config/sops/age/yubi-nix.txt";
    };
    ssh.credentials.backend = "yubikey";
  };
}
