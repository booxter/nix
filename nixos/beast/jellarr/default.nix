{
  imports = [
    ./assertions.nix
    ./libraries.nix
    ./plugins.nix
    ./server.nix
    ./users.nix
  ];

  host.jellarr.enable = true;
}
