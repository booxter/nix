{ config, lib, ... }:
{
  options.host.nixpkgsReview.builders = lib.mkOption {
    type = lib.types.str;
    readOnly = true;
    internal = true;
    description = "Nix builders made available to nixpkgs-review on this host.";
  };

  options.host.nixpkgsReview.communityBuilders = lib.mkOption {
    type = lib.types.lines;
    default = "";
    internal = true;
    description = "Review-only nix-community builders in Nix machines-file format.";
  };

  config.host.nixpkgsReview.builders =
    let
      configuredBuilders =
        if config.nix.buildMachines == [ ] then "" else config.environment.etc."nix/machines".text;
    in
    lib.concatStringsSep " ; " (
      lib.filter (builder: builder != "") (
        lib.splitString "\n" "${configuredBuilders}${config.host.nixpkgsReview.communityBuilders}"
      )
    );
}
