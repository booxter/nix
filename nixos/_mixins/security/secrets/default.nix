{ lib, ... }:
{
  # Install regular secrets through a sysinit unit so consumers can order
  # themselves after sops-install-secrets.service. Password secrets marked
  # neededForUsers still use the early users activation path.
  sops.useSystemdActivation = lib.mkDefault true;
}
