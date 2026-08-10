{
  config,
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
  realm = facts.realms.${config.host.realm};
  platformDirectory = if isDarwin then ../../darwin else ../../nixos;
  hostModule = platformDirectory + "/${hostname}";
in
{
  imports = [ ./host/assertions.nix ] ++ lib.optional (builtins.pathExists hostModule) hostModule;

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

    isProxmox = lib.mkOption {
      type = lib.types.bool;
      default = false;
      internal = true;
      description = "Whether this host is a Proxmox VE node.";
    };

    isDesktop = lib.mkOption {
      type = lib.types.bool;
      default = isDesktop;
      readOnly = true;
      internal = true;
      description = "Whether the host configuration includes a desktop environment.";
    };

    isOperatorSeat = lib.mkOption {
      type = lib.types.bool;
      default = hostSpec.isOperatorSeat or false;
      readOnly = true;
      internal = true;
      description = "Whether this host is used interactively for fleet development and administration.";
    };

    availability = lib.mkOption {
      type = lib.types.enum [
        "always"
        "intermittent"
      ];
      default = hostSpec.availability or "always";
      readOnly = true;
      internal = true;
      description = "Expected host availability for monitoring.";
    };

    isSecretsOperator = lib.mkOption {
      type = lib.types.bool;
      default = hostSpec.isSecretsOperator or false;
      readOnly = true;
      internal = true;
      description = "Whether this host manages repository secrets.";
    };

    hasYubiAgeIdentity = lib.mkOption {
      type = lib.types.bool;
      default = builtins.elem hostname facts.yubi.ageIdentity.hosts;
      readOnly = true;
      internal = true;
      description = "Whether YubiKey facts assign an age identity to this host.";
    };

    isVM = lib.mkOption {
      type = lib.types.bool;
      default = hostSpec.isVM or false;
      readOnly = true;
      internal = true;
      description = "Whether this host is a virtual machine.";
    };

    realm = lib.mkOption {
      type = lib.types.enum (builtins.attrNames facts.realms);
      default = hostSpec.realm;
      readOnly = true;
      internal = true;
      description = "Infrastructure and trust realm declared by host facts.";
    };

    management = {
      manageNetworkIdentity = lib.mkOption {
        type = lib.types.bool;
        default = realm.management.manageNetworkIdentity;
        readOnly = true;
        internal = true;
        description = "Whether this host manages its network identity.";
      };

      managePasswordSecrets = lib.mkOption {
        type = lib.types.bool;
        default = realm.management.managePasswordSecrets;
        readOnly = true;
        internal = true;
        description = "Whether this host manages local password secrets.";
      };

      sudoWheelNeedsPassword = lib.mkOption {
        type = lib.types.bool;
        default = realm.management.sudoWheelNeedsPassword;
        readOnly = true;
        internal = true;
        description = "Whether wheel users must enter a password for sudo.";
      };
    };

    username = lib.mkOption {
      type = lib.types.str;
      default = "ihrachyshka";
      readOnly = true;
      internal = true;
      description = "Primary user for managed hosts.";
    };

    userProfile = lib.mkOption {
      type = lib.types.enum [
        "nvidia"
        "personal"
      ];
      default = hostSpec.userProfile;
      readOnly = true;
      internal = true;
      description = "User environment profile declared by host facts.";
    };

  };

  config = {
    nixpkgs.hostPlatform = system;
    networking.hostName = hostname;
  };
}
