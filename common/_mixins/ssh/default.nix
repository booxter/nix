{
  imports = [
    ./known-hosts.nix
    ./ticket-server.nix
  ];

  services.openssh.enable = true;
}
