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
    roles = {
      developer.enable = true;
      workstation.enable = true;
    };
    features = {
      codex = {
        usageStatus.enable = false;
        resetCredits.enable = false;
        workUsageStatus.enable = true;
      };
      scm = {
        identity = "nvidia";
        sendEmail.transport = "nvidia";
      };
      email = {
        account = "nvidia";
        gmailctl.enable = false;
      };
      firefox.enable = false;
      homerow.enable = false;
    };
  };
  host.nix.cacheWarmer.enable = true;
}
