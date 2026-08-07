{
  config,
  hostInventory,
  hostSpec,
  inputs,
  lib,
  ...
}:
let
  hostname = hostSpec.name;
  hostPlatform = inputs.nixpkgs.lib.systems.elaborate hostSpec.platform;
  realm = hostInventory.realms.${config.host.realm};
  inherit (hostPlatform) isDarwin isLinux system;
  platformDirectory = if isDarwin then ../../darwin else ../../nixos;
  hostModule = platformDirectory + "/${hostname}";
  hostStorage = hostInventory.storage.hosts.${hostname} or { };
in
{
  imports = lib.optional (builtins.pathExists hostModule) hostModule;

  options.host = {
    platform = lib.mkOption {
      type = lib.types.str;
      default = system;
      readOnly = true;
      internal = true;
      description = "Nix platform declared by the host inventory.";
    };

    isDarwin = lib.mkOption {
      type = lib.types.bool;
      default = isDarwin;
      readOnly = true;
      internal = true;
      description = "Whether the inventory platform uses the Darwin kernel.";
    };

    isLinux = lib.mkOption {
      type = lib.types.bool;
      default = isLinux;
      readOnly = true;
      internal = true;
      description = "Whether the inventory platform uses the Linux kernel.";
    };

    isBuilder = lib.mkOption {
      type = lib.types.bool;
      default = hostSpec ? builder;
      readOnly = true;
      internal = true;
      description = "Whether this host is a Nix builder.";
    };

    isDesktop = lib.mkOption {
      type = lib.types.bool;
      default = hostSpec.isDesktop or false;
      readOnly = true;
      internal = true;
      description = "Whether this host has a desktop environment.";
    };

    isOperatorSeat = lib.mkOption {
      type = lib.types.bool;
      default = hostSpec.isOperatorSeat or false;
      readOnly = true;
      internal = true;
      description = "Whether this host is used interactively for fleet development and administration.";
    };

    github.login = lib.mkOption {
      type = lib.types.str;
      default = hostInventory.user.github.login;
      readOnly = true;
      internal = true;
      description = "GitHub login for the primary user on this host.";
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

    hasTouchId = lib.mkOption {
      type = lib.types.bool;
      default = hostSpec.hasTouchId or false;
      readOnly = true;
      internal = true;
      description = "Whether this host has Touch ID-backed authentication.";
    };

    isSecretsOperator = lib.mkOption {
      type = lib.types.bool;
      default = hostSpec.isSecretsOperator or false;
      readOnly = true;
      internal = true;
      description = "Whether this host manages repository secrets.";
    };

    hasHardwareAgeIdentity = lib.mkOption {
      type = lib.types.bool;
      default = config.host.hasTouchId || config.host.hasYubiAgeIdentity;
      readOnly = true;
      internal = true;
      description = "Whether this host can use a hardware-backed age identity.";
    };

    hasYubiAgeIdentity = lib.mkOption {
      type = lib.types.bool;
      default = builtins.elem hostname hostInventory.yubi.ageIdentity.hosts;
      readOnly = true;
      internal = true;
      description = "Whether the YubiKey inventory assigns an age identity to this host.";
    };

    isVM = lib.mkOption {
      type = lib.types.bool;
      default = hostSpec.isVM or false;
      readOnly = true;
      internal = true;
      description = "Whether this host is a virtual machine.";
    };

    boot.requiresInteractiveUnlock = lib.mkOption {
      type = lib.types.bool;
      default = false;
      internal = true;
      description = "Whether boot requires an interactive disk-unlock credential.";
    };

    nixStore.capacityGiB = lib.mkOption {
      type = with lib.types; nullOr ints.positive;
      default =
        if hostSpec ? nixStoreCapacityGiB then
          hostSpec.nixStoreCapacityGiB
        else if hostSpec.isVM or false then
          hostSpec.diskSize or 100
        else
          null;
      readOnly = true;
      internal = true;
      description = "Capacity of the filesystem containing /nix/store, when declared by inventory.";
    };

    realm = lib.mkOption {
      type = lib.types.enum (builtins.attrNames hostInventory.realms);
      default = hostSpec.realm;
      readOnly = true;
      internal = true;
      description = "Infrastructure and trust realm declared by the host inventory.";
    };

    secretDomain = lib.mkOption {
      type = lib.types.str;
      default = hostInventory.realms.${config.host.realm}.secretDomain;
      readOnly = true;
      internal = true;
      description = "SOPS secret domain selected for this host.";
    };

    storage.volumes = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            mountPoint = lib.mkOption {
              type = lib.types.str;
              description = "Filesystem mount point.";
            };
            device = lib.mkOption {
              type = lib.types.str;
              description = "Filesystem device.";
            };
            fsType = lib.mkOption {
              type = lib.types.str;
              description = "Filesystem type.";
            };
          };
        }
      );
      default = hostStorage.volumes or { };
      readOnly = true;
      internal = true;
      description = "Storage volumes declared for this host by inventory.";
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

    remoteAccess = {
      appleRemoteManagement = lib.mkOption {
        type = lib.types.bool;
        default = realm.services.remoteAccess.appleRemoteManagement or false;
        readOnly = true;
        internal = true;
        description = "Whether Apple Remote Management is available in this realm.";
      };

      vncClient = lib.mkOption {
        type = lib.types.bool;
        default = realm.services.remoteAccess.vncClient or false;
        readOnly = true;
        internal = true;
        description = "Whether this host should provide the fleet VNC client.";
      };

      x11 = lib.mkOption {
        type = lib.types.bool;
        default = realm.services.remoteAccess.x11 or false;
        readOnly = true;
        internal = true;
        description = "Whether X11 forwarding is available in this realm.";
      };
    };

    username = lib.mkOption {
      type = lib.types.str;
      default = hostSpec.username;
      readOnly = true;
      internal = true;
      description = "Primary user declared by the host inventory.";
    };

    userProfile = lib.mkOption {
      type = lib.types.enum [
        "nvidia"
        "personal"
      ];
      default = hostSpec.userProfile;
      readOnly = true;
      internal = true;
      description = "User environment profile declared by the host inventory.";
    };

    ups.client.server = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = hostSpec.upsHost or null;
      readOnly = true;
      internal = true;
      description = "Inventory host providing this host's UPS service.";
    };
  };

  config = {
    assertions = [
      {
        assertion = isDarwin != isLinux;
        message = "Inventory platform ${system} must identify exactly one supported kernel.";
      }
      {
        assertion = !config.host.isSecretsOperator || config.host.hasHardwareAgeIdentity;
        message = "Secrets operator ${hostname} must have a hardware-backed age identity.";
      }
    ];

    nixpkgs.hostPlatform = system;
    networking.hostName = hostname;
    system.stateVersion = hostSpec.stateVersion;
  };
}
