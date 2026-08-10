{ config, lib, ... }:
let
  builder = config.host.nix.builder;
  hostNames =
    map (entry: entry.hostName) config.host.nix.builder-pool
    ++ lib.optional builder.enable builder.hostName;
in
{
  config.assertions = [
    {
      assertion = builtins.length hostNames == builtins.length (lib.unique hostNames);
      message = "Nix builders in realm '${config.host.realm}' must advertise unique hostnames";
    }
  ];
}
