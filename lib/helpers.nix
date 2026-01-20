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
          isDesktop
          isWork
          stateVersion
          ;
      };
      home-manager.useUserPackages = true;
      home-manager.users.${username} = ../home-manager;
    };
in
rec {
  mkHome =
    {
      stateVersion,
      username ? "ihrachyshka",
      platform ? "aarch64-darwin",
      isWork ? false,
      isDesktop ? false,
      extraModules ? [ ],
    }:
    inputs.home-manager.lib.homeManagerConfiguration {
      pkgs = inputs.nixpkgs.legacyPackages.${platform};
      extraSpecialArgs = {
        inherit
          inputs
          outputs
          username
          platform
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
      withHome ? true,
      isDesktop ? false,
      isWork ? false,
      isVM ? false,
      extraModules ? [ ],
      password ? null,
      ...
    }:
    inputs.nixpkgs.lib.nixosSystem {
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
      };
      modules = [
        ../common
        ../nixos
        inputs.disko.nixosModules.disko
      ]
      ++ inputs.nixpkgs.lib.optionals withHome [
        inputs.home-manager.nixosModules.home-manager
        (commonHMConfig {
          inherit
            inputs
            outputs
            username
            isDesktop
            isWork
            stateVersion
            ;
        })

        (
          { ... }:
          let
            pkgs = inputs.nixpkgs.legacyPackages.${platform};
          in
          {
            users.defaultUserShell = pkgs.zsh;
          }
        )
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
                security.sudo.wheelNeedsPassword = false;
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
                virtualisation.vmVariant.virtualisation = {
                  # limit cores to avoid overloading host
                  cores = min cores 8;
                  memorySize = memorySize * 1024;
                  diskSize = diskSize * 1024;

                  host.pkgs = (
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
                                  url = "https://github.com/booxter/glib/pull/1.patch";
                                  hash = "sha256-guoEc+u1YX31h+ZTqseDVEy4P6uZ5/OMgP4W5nKxSpw=";
                                })
                              ];
                          });
                        })
                      ];
                    }
                  );
                  graphics = false;
                };
              }
            )

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
                  net = [
                    {
                      model = "virtio";
                      bridge = "vmbr0";
                    }
                  ];
                  scsi = [ { file = "local:${toString diskSize}"; } ];
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
        withHome = false;
        extraModules =
          extraModules
          ++ [
            inputs.proxmox-nixos.nixosModules.proxmox-ve

            (
              { pkgs, ... }:
              let
                brname = "vmbr0";
              in
              {
                nixpkgs.overlays = [
                  inputs.proxmox-nixos.overlays.${platform}
                ];

                services.proxmox-ve = {
                  inherit ipAddress;
                  enable = true;
                };

                # Work around issues with proxmox-nixos modules setting these as a single string.
                # https://github.com/SaumonNet/proxmox-nixos/pull/213
                services.openssh.settings.AcceptEnv = inputs.nixpkgs.lib.mkForce [
                  "LANG"
                  "LC_*"
                ];

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

        # configure binary cache substituters
        {
          nix = {
            settings = {
              extra-substituters = [
                "https://nixos-raspberrypi.cachix.org"
              ];
              extra-trusted-public-keys = [
                "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI="
              ];
            };
          };
        }

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
                cfg = config.boot.loader.raspberryPi;
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
      isDesktop ? false,
      isWork ? false,
      ci ? false,
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
          isDesktop
          isWork
          ci
          ;
      };
      modules = [
        inputs.nix-homebrew.darwinModules.nix-homebrew
        ../common
        ../darwin

        inputs.home-manager.darwinModules.home-manager
        (commonHMConfig {
          inherit
            inputs
            outputs
            username
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
}
