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
  builders =
    lib.mapAttrsToList (name: builder: builder // { hostName = name; }) poolBuilders
    ++ config.host.nix.nixpkgs.additional-builders;
  builderString = lib.concatStringsSep " ; " (map formatBuilder builders);
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
      default = builderString;
      readOnly = true;
      internal = true;
      description = "Complete machines-file argument for nixpkgs builds.";
    };
  };
}
