{ config, lib, ... }:
{
  options.host.nixpkgsReview.builders = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    internal = true;
    description = "Nix builders made available to nixpkgs-review on this host.";
  };

  config.host.nixpkgsReview.builders =
    let
      configuredBuilders =
        if config.nix.buildMachines == [ ] then "" else config.environment.etc."nix/machines".text;
    in
    lib.filter (builder: builder != "") (lib.splitString "\n" configuredBuilders);
}
