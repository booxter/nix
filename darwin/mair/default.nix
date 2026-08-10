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
    secrets.operatorAgeIdentity = {
      backend = "secure-enclave";
      path = "/Users/${config.host.username}/.config/sops/age/mair-se.txt";
    };
    remote-control = {
      client = {
        vnc.enable = true;
        wayland.enable = true;
        x11.enable = true;
      };
      server.vnc.enable = true;
    };
    secretive.enable = true;
    wireguard.client = {
      enable = true;
      network = "home";
      address = "10.83.0.10";
      publicKey = facts.public-keys.wireguard.home-mair;
      privateKeySecret = "wireguard/gw/privateKey";
    };
  };

}
