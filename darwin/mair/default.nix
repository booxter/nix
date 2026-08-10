{
  config,
  facts,
  ...
}:
{
  system.stateVersion = 6;

  imports = [
    ./opencode.nix
  ];

  host = {
    hardware.isLaptop = true;
    network.interfaces.en0.kind = "wireless";
    security = {
      secrets.operator.ageIdentity = {
        backend = "secure-enclave";
        path = "/Users/${config.host.username}/.config/sops/age/mair-se.txt";
      };
      ssh.credentials.backend = "secretive";
    };
    userEnvironment = {
      roles = {
        developer.enable = true;
        workstation.enable = true;
      };
      features.codex.warmer.enable = true;
    };
    remote-control = {
      client = {
        enable = true;
        wayland.enable = true;
      };
      server.vnc.enable = true;
    };
    wireguard.client = {
      enable = true;
      network = "home";
      address = "10.83.0.10";
      publicKey = facts.public-keys.wireguard.home-mair;
      privateKeySecret = "wireguard/gw/privateKey";
    };
  };

}
