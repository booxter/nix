{ lib, ... }:
{
  options.host.user.passwords.sops.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Whether to provision root and primary-user password hashes from SOPS.";
  };
}
