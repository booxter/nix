{ isWork, lib, ... }:
{
  imports = [ ./known-hosts.nix ] ++ lib.optionals (!isWork) [ ./ticket-server.nix ];

  services.openssh.enable = true;
}
