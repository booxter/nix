{
  config,
  lib,
  ...
}:
let
  username = config.host.username;
  readPublicKey = import ../../common/_lib/read-public-key.nix { inherit lib; };
in
{
  system.stateVersion = 5;

  host.hardware.isLaptop = true;
  host.network.interfaces = {
    en0.kind = "wireless";
    en7.kind = "ethernet";
  };
  host.security.secrets.operator.ageIdentity = {
    backend = "secure-enclave";
    path = "/Users/${username}/Library/Application Support/sops/age/work.txt";
  };
  host.ssh.operator.authorizedKeys = [
    (readPublicKey ../../common/_mixins/ssh/public-keys/jgwxhwdl4x.pub)
    (readPublicKey ../../common/_mixins/ssh/public-keys/jgwxhwdl4x-nix-builder.pub)
  ];
  host.userEnvironment = {
    preset = "nvidia";
    roles = {
      developer.enable = true;
      workstation.enable = true;
    };
  };
  host.nix.cacheWarmer.enable = true;
}
