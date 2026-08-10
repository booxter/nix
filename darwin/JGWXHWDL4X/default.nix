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
  host.secrets.operatorAgeIdentity = {
    backend = "secure-enclave";
    path = "/Users/${username}/Library/Application Support/sops/age/work.txt";
  };
  host.observability.lanWan.interfaces = [
    "en0"
    "en7"
  ];

  host.nix.cacheWarmer.enable = true;
}
