{
  config,
  facts,
  lib,
  ...
}:
{
  imports = [
    ./community.nix
    ./personal.nix
    ./work.nix
  ];

  options.host = {
    build.pools = lib.mkOption {
      type = with lib.types; listOf str;
      default = facts.realms.${config.host.realm}.build.pools;
      readOnly = true;
      internal = true;
      description = "Nix builder pools made available by the host realm.";
    };

    nixpkgsReview.extraBuilders = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      internal = true;
      description = "Review-only Nix builders in machines-file format.";
    };
  };
}
