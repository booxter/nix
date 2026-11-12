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
  services.openssh.extraConfig = ''
    AcceptEnv SOPS_KEYSERVICE SOPS_ENABLE_LOCAL_KEYSERVICE
  '';
}
