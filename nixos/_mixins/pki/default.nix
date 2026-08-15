{ lib, ... }:
{
  imports = [ ./authority.nix ];

  options.host.pki.server = lib.mkOption {
    type = lib.types.nullOr (lib.types.submodule { });
    default = null;
    description = "Internal PKI authority service hosted by this machine.";
  };
}
