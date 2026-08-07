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
      default = hostSpec.isBuilder or false;
      readOnly = true;
      internal = true;
      description = "Whether this host is a Nix builder.";
    };

    builder.supportsNspawnTests = lib.mkOption {
      type = lib.types.bool;
      default = hostSpec.nspawnTestBuilder or false;
      readOnly = true;
      internal = true;
      description = "Whether this builder supports nspawn-based NixOS tests.";
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

    isCritical = lib.mkOption {
      type = lib.types.bool;
      default = hostSpec.critical or false;
      readOnly = true;
      internal = true;
      description = "Whether this host should avoid frequent unattended reboots.";
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
      {
        assertion = !config.host.builder.supportsNspawnTests || config.host.isBuilder;
        message = "nspawn test support requires ${hostname} to be a Nix builder.";
      }
    ];

    nixpkgs.hostPlatform = system;
    networking.hostName = hostname;
    system.stateVersion = hostSpec.stateVersion;
  };
}
