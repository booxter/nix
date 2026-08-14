{
  hostName,
  lib,
  system,
  ...
}:
{
  imports = [
    ./home.nix
    ./work.nix
  ];

  options.host = {
    realm = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "home";
      description = "Infrastructure and trust realm containing this host.";
    };

    management = {
      manageNetworkIdentity = lib.mkOption {
        type = lib.types.bool;
        description = "Whether this host manages its network identity.";
      };

    };

    username = lib.mkOption {
      type = lib.types.str;
      default = "ihrachyshka";
      readOnly = true;
      internal = true;
      description = "Primary user for managed hosts.";
    };

  };

  config = {
    nixpkgs.hostPlatform = system;
    networking.hostName = hostName;
  };
}
