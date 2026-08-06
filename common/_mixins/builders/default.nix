{ lib, ... }:
{
  imports = [
    ./community.nix
    ./personal.nix
    ./work.nix
  ];

  options.host.nixpkgsReview.extraBuilders = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    internal = true;
    description = "Review-only Nix builders in machines-file format.";
  };
}
