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
  inherit (hostPlatform) isDarwin isLinux system;
  platformDirectory = if isDarwin then ../../darwin else ../../nixos;
  hostModule = platformDirectory + "/${hostname}";
in
{
  imports = lib.optional (builtins.pathExists hostModule) hostModule;

  options.host = {
    platform = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      internal = true;
      description = "Nix platform declared by the host inventory.";
    };

    isDarwin = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
      internal = true;
      description = "Whether the inventory platform uses the Darwin kernel.";
    };

    isLinux = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
      internal = true;
      description = "Whether the inventory platform uses the Linux kernel.";
    };

    isBuilder = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
      internal = true;
      description = "Whether this host is a Nix builder.";
    };

    isDesktop = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
      internal = true;
      description = "Whether this host has a desktop environment.";
    };

    isLaptop = lib.mkOption {
      type = lib.types.bool;
      default = hostSpec.isLaptop or false;
      readOnly = true;
      internal = true;
      description = "Whether this host is intermittently available like a laptop.";
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
      default = config.host.hasYubiAgeIdentity || (config.host.isDarwin && config.host.isLaptop);
      readOnly = true;
      internal = true;
      description = "Whether this host can use a hardware-backed age identity.";
    };

    hasYubiAgeIdentity = lib.mkOption {
      type = lib.types.bool;
      default = builtins.elem hostname hostInventory.yubi.ageIdentityHosts;
      readOnly = true;
      internal = true;
      description = "Whether the YubiKey inventory assigns an age identity to this host.";
    };

    isWork = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
      internal = true;
      description = "Whether this is a work-managed host.";
    };

    isVM = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
      internal = true;
      description = "Whether this host is a virtual machine.";
    };

    isCritical = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
      internal = true;
      description = "Whether this host should avoid frequent unattended reboots.";
    };

    secretDomain = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      internal = true;
      description = "SOPS secret domain selected for this host.";
    };

    username = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      internal = true;
      description = "Primary user declared by the host inventory.";
    };

    ups.client.server = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
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
    sops.defaultSopsFile = lib.mkDefault (
      ../../secrets + "/${config.host.secretDomain}/${config.networking.hostName}.yaml"
    );
    host = {
      platform = system;
      inherit isDarwin isLinux;
      isBuilder = hostSpec.isBuilder or false;
      isCritical = hostSpec.critical or false;
      isDesktop = hostSpec.isDesktop or false;
      isVM = hostSpec.isVM or false;
      isWork = hostSpec.isWork or false;
      secretDomain = hostInventory.toSecretDomain hostSpec;
      ups.client.server = hostSpec.upsHost or null;
      username = hostSpec.username;
    };
  };
}
