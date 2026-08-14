{ config, lib, ... }:
let
  builders =
    if config.host.nix.builder.client.enable then
      lib.filterAttrs (_: builder: builtins.elem "nixpkgs" builder.uses) config.host.nix.builder-pool
    else
      { };
  formatList = values: if values == [ ] then "-" else lib.concatStringsSep "," values;
  formatBuilder =
    name: builder:
    lib.concatMapStringsSep " " toString [
      "${builder.protocol}://${builder.sshUser}@${name}"
      (formatList builder.systems)
      builder.sshKey
      builder.maxJobs
      builder.speedFactor
      (formatList builder.supportedFeatures)
      "-"
      "-"
    ];
  builderString = lib.concatStringsSep " ; " (lib.mapAttrsToList formatBuilder builders);
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
