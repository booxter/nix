{ config, lib, ... }:
let
  formatBuilder = import ../../_lib/format-nix-builder.nix { inherit lib; };
  builders =
    if config.host.nix.builderClient != null then
      lib.filterAttrs (_: builder: builtins.elem "nixpkgs" builder.uses) config.host.nix.builder-pool
    else
      { };
  builderString = lib.concatStringsSep " ; " (
    lib.mapAttrsToList (name: builder: formatBuilder (builder // { hostName = name; })) builders
  );
in
{
  options.host.nix.nixpkgs-review.builders = lib.mkOption {
    type = lib.types.str;
    default = builderString;
    readOnly = true;
    internal = true;
    description = "Complete nixpkgs-review machines-file argument.";
  };
}
