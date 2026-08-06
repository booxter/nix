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
in
{
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
      readOnly = true;
      internal = true;
      description = "Whether this host is intermittently available like a laptop.";
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
      isLaptop = hostSpec.isLaptop or false;
      isVM = hostSpec.isVM or false;
      isWork = hostSpec.isWork or false;
      secretDomain = hostInventory.toSecretDomain hostSpec;
      ups.client.server = hostSpec.upsHost or null;
      username = hostSpec.username;
    };
  };
}
