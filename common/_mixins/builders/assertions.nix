{ config, lib, ... }:
let
  builder = config.host.nix.builder;
  hostNames =
    map (entry: entry.hostName) (builtins.attrValues config.host.nix.builder-pool)
    ++ lib.optional builder.enable builder.hostName;
  externalWithoutPublicKeys = lib.filterAttrs (
    _: entry: entry.source == "external" && entry.publicKey == null
  ) config.host.nix.builder-pool;
in
{
  config.assertions = [
    {
      assertion = builtins.length hostNames == builtins.length (lib.unique hostNames);
      message = "Nix builders in realm '${config.host.realm}' must advertise unique hostnames";
    }
    {
      assertion = externalWithoutPublicKeys == { };
      message = "external Nix builders must declare SSH public keys";
    }
  ];
}
