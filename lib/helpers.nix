{
  inputs,
  outputs,
  ...
}:
let
  commonHMConfig =
    {
      inputs,
      outputs,
      username,
      hmFull,
      isDesktop,
      isWork,
      stateVersion,
    }:
    {
      home-manager.extraSpecialArgs = {
        inherit
          inputs
          outputs
          username
          hmFull
          isDesktop
          isWork
          stateVersion
          ;
      };
      home-manager.useUserPackages = true;
      home-manager.users.${username} = ../home-manager;
    };
  upsNonVmShutdownDelaySeconds = 900;
  upsShutdownDelaySeconds =
    isVM: if isVM then builtins.div upsNonVmShutdownDelaySeconds 2 else upsNonVmShutdownDelaySeconds;
  mkVmHostPkgs =
    virtPlatform:
    import inputs.nixpkgs {
      system = virtPlatform;
      overlays = [
        (final: prev: {
          # Fix qemu hanging on beefy VMs due to fd limit exhaustion.
          # Use heap based fdsets in g_poll.
          glib = prev.glib.overrideAttrs (old: {
            patches =
              old.patches or [ ]
              ++ prev.lib.optionals prev.stdenv.hostPlatform.isDarwin [
                (prev.fetchpatch {
                  url = "https://gitlab.gnome.org/ihar.hrachyshka/glib/-/commit/9bd63d0d265bd8128ffdee9cd5c3cc9821b37e92.patch";
                  hash = "sha256-iwrqiTQbKP/PUEXZuOhQo6tBKCgelHNe0lFTC7hzxB8=";
                  excludes = [ ".gitlab-ci.yml" ];
                })
              ];
          });
        })
      ];
    };
  mkLocalVmVariantVirtualisation = virtPlatform: {
    host.pkgs = mkVmHostPkgs virtPlatform;
    graphics = false;
  };
in
rec {
  mkHome =
    {
      stateVersion,
      username ? "ihrachyshka",
      platform ? "aarch64-darwin",
      homeManagerInput ? inputs.home-manager,
      hmFull ? true,
      isWork ? false,
      isDesktop ? false,
      extraModules ? [ ],
    }:
    homeManagerInput.lib.homeManagerConfiguration {
      pkgs = inputs.nixpkgs.legacyPackages.${platform};
      extraSpecialArgs = {
        inherit
          inputs
          outputs
          username
          platform
          hmFull
          stateVersion
          isDesktop
          isWork
          ;
      };
      modules = [
        ../home-manager
      ]
      ++ extraModules;
    };

  mkNixos =
    {
      hostname,
      stateVersion,
      username ? "ihrachyshka",
      platform ? "x86_64-linux",
      virtPlatform ? platform,
      homeManagerInput ? inputs.home-manager,
      hmFull ? true,
      isDesktop ? false,
      isWork ? false,
      isVM ? false,
      nixpkgsInput ? inputs.nixpkgs,
      extraModules ? [ ],
      password ? null,
      ...
    }:
    nixpkgsInput.lib.nixosSystem {
      specialArgs = {
        inherit
          inputs
          outputs
          hostname
          platform
          virtPlatform
          username
          stateVersion
          isVM
          isDesktop
          isWork
          ;
        upsShutdownDelaySeconds = upsShutdownDelaySeconds isVM;
      };
      modules = [
        ../common
        ../nixos
        inputs.disko.nixosModules.disko
        inputs.sops-nix.nixosModules.sops
        homeManagerInput.nixosModules.home-manager
        (commonHMConfig {
          inherit
            inputs
            outputs
            username
            hmFull
            isDesktop
            isWork
            stateVersion
            ;
        })
      ]
      ++ inputs.nixpkgs.lib.optionals (password != null) [
        (
          { ... }:
          {
            users.users = {
              root.hashedPassword = password;
              ${username}.hashedPassword = password;
            };
          }
        )
      ]
      ++ extraModules;
    };

  mkVM =
    args@{
      extraModules ? [ ],
      vmMode ? "proxmox",
      sshPort ? null,
      username ? "ihrachyshka",
      platform ? "x86_64-linux",
      virtPlatform ? platform,
      cores ? 4,
      memorySize ? 8, # GB
      diskSize ? 100, # GB
      hostname,
      proxNode ? "prx1-lab", # TODO: can we avoid picking a node in a cluster?
      ...
    }:
    let
      _ =
        if
          builtins.elem vmMode [
            "qemu"
            "proxmox"
          ]
        then
          null
        else
          throw "Unsupported mkVM vmMode `${vmMode}`; expected one of: qemu, proxmox";
    in
    mkNixos (
      args
      // {
        isVM = true;
        extraModules =
          extraModules
          ++ [
            (
              { ... }:
              {
                services.getty.autologinUser = username;
              }
            )

            (
              { modulesPath, ... }:
              {
                imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];
                services.qemuGuest.enable = true;
              }
            )

            # build-vm (local) vms
            (
              { ... }:
              let
                min = x: y: if x < y then x else y;
              in
              {
                virtualisation.vmVariant.virtualisation = (mkLocalVmVariantVirtualisation virtPlatform) // {
                  # limit cores to avoid overloading host
                  cores = min cores 8;
                  memorySize = memorySize * 1024;
                  diskSize = diskSize * 1024;
                };
              }
            )
            (
              { config, ... }:
              {
                system.build.vmQemu = config.virtualisation.vmVariant.virtualisation.host.pkgs.qemu;
              }
            )
          ]
          ++ inputs.nixpkgs.lib.optionals (vmMode == "qemu") [
            (
              { lib, ... }:
              {
                # Keep qemu-mode VM configs evaluable when system.build.toplevel is requested.
                fileSystems."/" = lib.mkDefault {
                  device = "/dev/disk/by-label/nixos";
                  fsType = "ext4";
                };
                boot.loader.grub.devices = lib.mkDefault [ "nodev" ];
              }
            )
          ]
          ++ inputs.nixpkgs.lib.optionals (vmMode == "proxmox") [
            # proxmox vms
            inputs.proxmox-nixos.nixosModules.declarative-vms
            (
              { ... }:
              {
                imports = [
                  (import ../disko { device = "/dev/sda"; })
                ];
                virtualisation.proxmox = {
                  inherit cores;
                  name = hostname;
                  node = proxNode;
                  autoInstall = true;
                  memory = memorySize * 1024;
                  cpu.cputype = "host";
                  agent = {
                    enabled = true;
                    type = "virtio";
                    freeze-fs-on-backup = true;
                    fstrim_cloned_disks = true;
                  };
                  net = [
                    {
                      model = "virtio";
                      bridge = "vmbr0";
                    }
                  ];
                  scsi = [
                    {
                      file = "local:${toString diskSize}";
                      discard = "on";
                    }
                  ];
                  onboot = true;
                };

                boot.growPartition = true;
              }
            )
          ]
          ++ inputs.nixpkgs.lib.optionals (sshPort != null) [
            (
              { ... }:
              {
                virtualisation.vmVariant.virtualisation.forwardPorts = [
                  {
                    from = "host";
                    guest.port = 22;
                    host.port = sshPort;
                  }
                ];
              }
            )
          ];
      }
    );

  mkBM =
    {
      mkHost,
      name,
      virtPlatform,
      localPlatform ? (
        if inputs.nixpkgs.lib.hasSuffix "-darwin" virtPlatform then "aarch64-linux" else null
      ),
      localExtraModules ? [ ],
      ...
    }@args:
    let
      hostArgs = removeAttrs (args // { hostname = args.hostname or name; }) [
        "mkHost"
        "name"
        "virtPlatform"
        "localPlatform"
        "localExtraModules"
      ];
      cfg = mkHost hostArgs;
      localName = "local-${name}vm";
      localCfg = builtins.tryEval (
        cfg.extendModules {
          modules = [
            (
              {
                lib,
                ...
              }:
              {
                virtualisation.vmVariant.virtualisation = mkLocalVmVariantVirtualisation virtPlatform;
              }
              // lib.optionalAttrs (localPlatform != null) {
                nixpkgs.hostPlatform = lib.mkForce localPlatform;
              }
            )
          ]
          ++ localExtraModules;
        }
      );
    in
    {
      "${name}" = cfg;
      "${localName}" =
        if localCfg.success then
          localCfg.value
        else
          throw "Cannot derive `${localName}` from `${name}`; expected a nixosSystem with extendModules support.";
    };

  mkProxmox =
    args@{
      netIface,
      ipAddress,
      macAddress ? null,
      isVM ? false,
      extraModules ? [ ],
      ...
    }:
    let
      platform = "x86_64-linux";
    in
    mkNixos (
      args
      // {
        inherit platform;
        hmFull = false;
        extraModules =
          extraModules
          ++ [
            inputs.proxmox-nixos.nixosModules.proxmox-ve

            (
              { ... }:
              {
                host.isProxmox = true;
              }
            )

            (
              { pkgs, ... }:
              let
                brname = "vmbr0";
              in
              {
                # Hypervisors upgrade on a separate schedule to avoid
                # disrupting guest VMs running on top.
                system.autoUpgrade.dates = "Sun 03:00";

                nixpkgs.overlays = [
                  inputs.proxmox-nixos.overlays.${platform}
                  (final: prev: {
                    pve-manager = prev.pve-manager.overrideAttrs (old: {
                      patches = (old.patches or [ ]) ++ [
                        ./patches/pve-manager-disable-subscription-popup.patch
                      ];
                    });
                  })
                ];

                services.proxmox-ve = {
                  inherit ipAddress;
                  enable = true;
                };

                # Some packages useful when debugging Proxmox VE.
                environment.systemPackages = with pkgs; [
                  bridge-utils
                ];

                # Bridge to the LAN, while retaining IP address on the main
                # interface, with its MAC address - as expected by DHCP server.
                services.proxmox-ve.bridges = [ brname ];

                networking.useNetworkd = true;
                systemd.network.enable = true;

                services.resolved.settings.Resolve = {
                  ResolveUnicastSingleLabel = true;
                };

                systemd.network.networks."10-lan" = {
                  matchConfig.Name = [ netIface ];
                  networkConfig = {
                    Bridge = brname;
                  };
                };

                systemd.network.netdevs."10-lan-bridge" = {
                  netdevConfig = {
                    Name = brname;
                    Kind = "bridge";
                  }
                  // inputs.nixpkgs.lib.optionalAttrs (macAddress != null) {
                    MACAddress = macAddress;
                  };
                };

                systemd.network.networks."10-lan-bridge" = {
                  matchConfig.Name = brname;
                  networkConfig = {
                    IPv6AcceptRA = true;
                    DHCP = "ipv4";
                  };
                  linkConfig = {
                    RequiredForOnline = "routable";
                  };
                };
              }
            )
          ]
          ++ inputs.nixpkgs.lib.optionals isVM [
            (
              { ... }:
              {
                virtualisation.vmVariant.virtualisation.forwardPorts =
                  let
                    proxmoxPort = 8006;
                  in
                  [
                    {
                      from = "host";
                      guest.port = proxmoxPort;
                      host.port = proxmoxPort;
                    }
                  ];
              }
            )
          ];
      }
    );

  mkRaspberryPi =
    {
      hostname,
      stateVersion,
      username ? "ihrachyshka",
      platform ? "aarch64-linux",
      homeManagerInput ? inputs.home-manager,
      hmFull ? true,
      isDesktop ? false,
      isWork ? false,
      isVM ? false,
      extraModules ? [ ],
    }:
    inputs.nixos-raspberrypi.lib.nixosSystem {
      specialArgs = {
        inherit
          inputs
          outputs
          hostname
          platform
          username
          stateVersion
          hmFull
          isDesktop
          isWork
          isVM
          ;
        nixos-raspberrypi = inputs.nixos-raspberrypi;
      };
      system = platform;
      modules = [
        ../common
        ../nixos
        inputs.sops-nix.nixosModules.sops
        homeManagerInput.nixosModules.home-manager
        (commonHMConfig {
          inherit
            inputs
            outputs
            username
            hmFull
            isDesktop
            isWork
            stateVersion
            ;
        })

        # base hardware modules
        {
          imports = with inputs.nixos-raspberrypi.nixosModules; [
            sd-image
            raspberry-pi-5.base
            raspberry-pi-5.display-vc4
            raspberry-pi-5.bluetooth
          ];
        }

        # bootloader
        (
          { config, ... }:
          {
            system.nixos.tags =
              let
                cfg = config.boot.loader."raspberry-pi";
              in
              [
                "raspberry-pi-${cfg.variant}"
                cfg.bootloader
                config.boot.kernelPackages.kernel.version
              ];
          }
        )

      ]
      ++ extraModules;
    };

  mkDarwin =
    {
      hostname,
      stateVersion,
      hmStateVersion,
      username ? "ihrachyshka",
      platform ? "aarch64-darwin",
      homeManagerInput ? inputs.home-manager,
      hmFull ? true,
      isDesktop ? false,
      isWork ? false,
      extraModules ? [ ],
    }:
    inputs.nix-darwin.lib.darwinSystem {
      specialArgs = {
        inherit
          inputs
          outputs
          hostname
          platform
          username
          stateVersion
          hmStateVersion
          hmFull
          isDesktop
          isWork
          ;
        # If we ever add macOS VMs, thread isVM here and compute accordingly.
        upsShutdownDelaySeconds = upsShutdownDelaySeconds false;
      };
      modules = [
        inputs.nix-homebrew.darwinModules.nix-homebrew
        inputs.sops-nix.darwinModules.sops
        ../common
        ../darwin

        homeManagerInput.darwinModules.home-manager
        (commonHMConfig {
          inherit
            inputs
            outputs
            username
            hmFull
            isDesktop
            isWork
            ;
          stateVersion = hmStateVersion;
        })
      ]
      ++ extraModules;
    };

  forAllSystems = inputs.nixpkgs.lib.genAttrs [
    "aarch64-linux"
    "x86_64-linux"
    "aarch64-darwin"
    "x86_64-darwin"
  ];
  inherit mkVmHostPkgs;
}
