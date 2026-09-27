{
  config,
  lib,
  options,
  ...
}:
let
  formatBuilder = import ../../_lib/format-nix-builder.nix { inherit lib; };
  poolBuilders =
    if config.host.nix.builderClient != null then
      lib.filterAttrs (_: builder: builtins.elem "nixpkgs" builder.uses) config.host.nix.builder-pool
    else
      { };
  localPoolBuilders = lib.filterAttrs (_: builder: !builder.community) poolBuilders;
  builders =
    lib.mapAttrsToList (name: builder: builder // { hostName = name; }) poolBuilders
    ++ config.host.nix.nixpkgs.additional-builders;
  localBuilders =
    lib.mapAttrsToList (name: builder: builder // { hostName = name; }) localPoolBuilders
    ++ config.host.nix.nixpkgs.additional-builders;
  formatBuilders = values: lib.concatStringsSep " ; " (map formatBuilder values);
in
{
  options.host.nix.nixpkgs = {
    additional-builders = lib.mkOption {
      type = options.nix.buildMachines.type;
      default = [ ];
      internal = true;
      description = "Builders managed outside the fleet builder pool.";
    };

    builders = lib.mkOption {
      type = lib.types.str;
      default = formatBuilders builders;
      readOnly = true;
      internal = true;
      description = "Complete machines-file argument for nixpkgs builds.";
    };

    local-builders = lib.mkOption {
      type = lib.types.str;
      default = formatBuilders localBuilders;
      readOnly = true;
      internal = true;
      description = "Nixpkgs builders managed locally, excluding community builders.";
    };
  };
}
