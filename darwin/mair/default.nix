{
  config,
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
  };

}
