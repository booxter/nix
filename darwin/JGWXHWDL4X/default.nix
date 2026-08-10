{
  config,
  ...
}:
let
  username = config.host.username;
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
  host.userEnvironment = {
    preset = "nvidia";
    roles = {
      developer.enable = true;
      workstation.enable = true;
    };
  };
  host.nix.cacheWarmer.enable = true;
}
