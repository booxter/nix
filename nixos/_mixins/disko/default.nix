{ config, lib, ... }:
let
  layout = config.host.disko.layout;
in
{
  options.host.disko.layout = lib.mkOption {
    type = lib.types.nullOr (
      lib.types.enum [
        "plain"
        "luks"
      ]
    );
    default = null;
    description = "Managed root disk layout, or null when disk layout is managed externally.";
  };

  config = lib.mkMerge [
    (lib.mkIf (layout == "plain") (import ./plain.nix { }))
    (lib.mkIf (layout == "luks") (import ./luks.nix { }))
  ];
}
