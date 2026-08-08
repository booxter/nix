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
  hostModule = platformDirectory + "/${hostname}/default.nix";
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

    desktop.environment = lib.mkOption {
      type = with lib.types; nullOr (enum [ "hyprland" ]);
      default = hostSpec.desktop.environment or null;
      readOnly = true;
      internal = true;
      description = "Desktop environment selected by the host inventory.";
    };

    display = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            kvm = lib.mkOption {
              type = lib.types.str;
              description = "Shared KVM providing this host's external displays.";
            };

            drmCard = lib.mkOption {
              type = with lib.types; nullOr str;
              default = null;
              description = "DRM card connected to the shared displays.";
            };

            scale = lib.mkOption {
              type = with lib.types; nullOr number;
              default = null;
              description = "Logical scale used for the shared displays.";
            };

            primary = lib.mkOption {
              type = with lib.types; nullOr str;
              default = null;
              description = "Primary monitor in the shared KVM setup.";
            };

            monitors = lib.mkOption {
              type = lib.types.attrsOf (
                lib.types.submodule {
                  options = {
                    connector = lib.mkOption {
                      type = with lib.types; nullOr str;
                      default = null;
                      description = "Host display connector attached to this monitor.";
                    };

                    nativeMode = {
                      width = lib.mkOption {
                        type = lib.types.ints.positive;
                        description = "Native monitor width in pixels.";
                      };

                      height = lib.mkOption {
                        type = lib.types.ints.positive;
                        description = "Native monitor height in pixels.";
                      };

                      refreshRate = lib.mkOption {
                        type = lib.types.number;
                        description = "Native monitor refresh rate in hertz.";
                      };
                    };

                    position = {
                      x = lib.mkOption {
                        type = lib.types.int;
                        description = "Logical horizontal monitor position.";
                      };

                      y = lib.mkOption {
                        type = lib.types.int;
                        description = "Logical vertical monitor position.";
                      };
                    };
                  };
                }
              );
              description = "Shared monitors with host-specific connector mappings.";
            };
          };
        }
      );
      default = hostInventory.displaysByHost.${hostname} or null;
      readOnly = true;
      internal = true;
      description = "Display setup derived from shared KVM inventory.";
    };

    isDesktop = lib.mkOption {
      type = lib.types.bool;
      default = (hostSpec.isDesktop or false) || config.host.desktop.environment != null;
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

    network = {
      primaryInterface = lib.mkOption {
        type = with lib.types; nullOr str;
        default = hostSpec.network.primaryInterface or null;
        readOnly = true;
        internal = true;
        description = "Primary network interface declared by inventory.";
      };

      pauseDisabledInterfaces = lib.mkOption {
        type = with lib.types; listOf str;
        default = hostSpec.network.pauseDisabledInterfaces or [ ];
        readOnly = true;
        internal = true;
        description = "Interfaces whose hardware pause frames should be disabled.";
      };

      lanWanInterfaces = lib.mkOption {
        type = with lib.types; listOf str;
        default =
          hostSpec.network.lanWanInterfaces or (lib.optional (
            config.host.network.primaryInterface != null
          ) config.host.network.primaryInterface);
        readOnly = true;
        internal = true;
        description = "Interfaces used for LAN/WAN traffic accounting.";
      };
    };

    boot = {
      requiresInteractiveUnlock = lib.mkOption {
        type = lib.types.bool;
        default =
          config.host.storage.systemDisk != null && config.host.storage.systemDisk.layout == "luks-btrfs";
        readOnly = true;
        internal = true;
        description = "Whether boot requires an interactive disk-unlock credential.";
      };

      remoteUnlock = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = config.host.storage.useInventory && (hostSpec.boot.remoteUnlock.enable or false);
          readOnly = true;
          internal = true;
          description = "Whether inventory enables remote initrd disk unlock.";
        };

        interface = lib.mkOption {
          type = with lib.types; nullOr str;
          default = hostSpec.boot.remoteUnlock.interface or null;
          readOnly = true;
          internal = true;
          description = "Network interface used for remote initrd disk unlock.";
        };

        kernelModules = lib.mkOption {
          type = with lib.types; listOf str;
          default = hostSpec.boot.remoteUnlock.kernelModules or [ ];
          readOnly = true;
          internal = true;
          description = "Kernel modules required by the initrd unlock network interface.";
        };
      };
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

    storage.useInventory = lib.mkOption {
      type = lib.types.bool;
      default = true;
      internal = true;
      description = "Whether this configuration represents the host's physical storage inventory.";
    };

    storage.systemDisk = lib.mkOption {
      type =
        with lib.types;
        nullOr (submodule {
          options = {
            device = lib.mkOption {
              type = str;
              description = "Block device containing the operating system.";
            };
            layout = lib.mkOption {
              type = enum [
                "ext4"
                "luks-btrfs"
              ];
              description = "Partitioning and filesystem layout for the operating system.";
            };
            transport = lib.mkOption {
              type = nullOr (enum [
                "nvme"
                "sas"
                "sata"
              ]);
              default = null;
              description = "Physical transport used by the system disk.";
            };
          };
        });
      default =
        if config.host.isVM || !config.host.storage.useInventory then
          {
            device = "/dev/sda";
            layout = "ext4";
          }
        else
          hostStorage.systemDisk or null;
      readOnly = true;
      internal = true;
      description = "System disk installation layout declared by inventory.";
    };

    storage.volumes = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            device = lib.mkOption {
              type = lib.types.str;
              description = "Filesystem device.";
            };
            fsType = lib.mkOption {
              type = lib.types.str;
              description = "Filesystem type.";
            };
            mounts = lib.mkOption {
              type = lib.types.attrsOf (
                lib.types.submodule {
                  options = {
                    mountPoint = lib.mkOption {
                      type = lib.types.str;
                      description = "Filesystem mount point.";
                    };
                    snapshots = lib.mkOption {
                      type = lib.types.bool;
                      default = true;
                      description = "Whether the standard snapshot timeline applies to this mount.";
                    };
                    requiredForBoot = lib.mkOption {
                      type = lib.types.bool;
                      default = true;
                      description = "Whether boot requires this mount to succeed.";
                    };
                  };
                }
              );
              description = "Mounted subvolumes belonging to this storage volume.";
            };
          };
        }
      );
      default = if config.host.storage.useInventory then hostStorage.volumes or { } else { };
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

    remoteGui.server = {
      x11.enable = lib.mkOption {
        type = lib.types.bool;
        default = hostSpec.remoteGui.server.x11.enable or false;
        readOnly = true;
        internal = true;
        description = "Whether this host accepts remote X11 applications over SSH.";
      };

      wayland.enable = lib.mkOption {
        type = lib.types.bool;
        default = hostSpec.remoteGui.server.wayland.enable or false;
        readOnly = true;
        internal = true;
        description = "Whether this host accepts remote Wayland applications through Waypipe.";
      };

      vnc = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = hostSpec.remoteGui.server.vnc.enable or false;
          readOnly = true;
          internal = true;
          description = "Whether this host exports its desktop over VNC.";
        };

        sshTunnel = lib.mkOption {
          type = lib.types.bool;
          default = hostSpec.remoteGui.server.vnc.sshTunnel or false;
          readOnly = true;
          internal = true;
          description = "Whether VNC clients must tunnel the connection through SSH.";
        };

        basePort = lib.mkOption {
          type = lib.types.port;
          default = hostSpec.remoteGui.server.vnc.basePort or 5900;
          readOnly = true;
          internal = true;
          description = "First VNC port allocated to this host's displays.";
        };
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
