{ config, lib, ... }:
let
  readPublicKey = import ../../common/_lib/read-public-key.nix { inherit lib; };
in
{
  system.stateVersion = 5;

  host.nix.builder = {
    client.enable = true;
    enable = true;
  };

  host.nix.cacheWarmer.enable = true;

  home-manager.users.${config.host.username}.host.hm.userEnvironment.preset = "personal";

  host.network.interfaces.en0.kind = "ethernet";

  host.remote-control = {
    client = {
      vnc.enable = true;
      x11.enable = true;
    };
    server.vnc.enable = true;
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

  host.ups.client.server = "frame";

  host.security = {
    smartCard.enable = true;
    secrets.operator.ageIdentity = {
      backend = "yubikey";
      path = "/Users/${config.host.username}/.config/sops/age/yubi-nix.txt";
    };
  };
}
