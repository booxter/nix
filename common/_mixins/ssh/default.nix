{ ... }:
{
  imports = [
    ./access.nix
    ./known-hosts.nix
    ./pre-boot.nix
    ./ticket-server.nix
    ./tickets.nix
  ];

  services.openssh.enable = true;
}
