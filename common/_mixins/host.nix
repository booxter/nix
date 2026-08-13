{
  facts,
  hostSpec,
  isDarwin,
  isDesktop,
  isLinux,
  lib,
  system,
  ...
}:
let
  hostname = hostSpec.name;
  platformDirectory = if isDarwin then ../../darwin else ../../nixos;
  hostModule = platformDirectory + "/${hostname}";
in
{
  imports = [
    ./host/assertions.nix
    ./host/home.nix
    ./host/work.nix
  ]
  ++ lib.optional (builtins.pathExists hostModule) hostModule;

  options.host = {
    platform = lib.mkOption {
      type = lib.types.str;
      default = system;
      readOnly = true;
      internal = true;
      description = "Nix platform selected by the host configuration constructor.";
    };

    isDarwin = lib.mkOption {
      type = lib.types.bool;
      default = isDarwin;
      readOnly = true;
      internal = true;
      description = "Whether the selected platform uses the Darwin kernel.";
    };

    isLinux = lib.mkOption {
      type = lib.types.bool;
      default = isLinux;
      readOnly = true;
      internal = true;
      description = "Whether the selected platform uses the Linux kernel.";
    };

    isDesktop = lib.mkOption {
      type = lib.types.bool;
      default = isDesktop;
      readOnly = true;
      internal = true;
      description = "Whether the host configuration includes a desktop environment.";
    };

    realm = lib.mkOption {
      type = lib.types.enum facts.hosts.realmNames;
      default = hostSpec.realm;
      readOnly = true;
      internal = true;
      description = "Infrastructure and trust realm declared by the host inventory.";
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
    networking.hostName = hostname;
  };
}
