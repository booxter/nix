{ isLaptop, lib, ... }:
{
  security.pam.services.sudo_local.touchIdAuth = lib.mkDefault isLaptop;
  security.pam.services.sudo_local.reattach = lib.mkDefault isLaptop;

  # Set sudo timeout to 30 minutes
  security.sudo.extraConfig = ''
    Defaults    timestamp_timeout=30
  '';
}
