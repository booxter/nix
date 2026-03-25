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
  upsNonVmShutdownDelaySeconds = 900;
  upsShutdownDelaySeconds =
    isVM: if isVM then builtins.div upsNonVmShutdownDelaySeconds 2 else upsNonVmShutdownDelaySeconds;
  # Apply upstream module PR deltas once and reuse the imported modules.
  #
  # NOTE: Patching the proxmox module source is architecture-agnostic, but
  # pkgs.applyPatches itself is a derivation and therefore has a build system.
  # Use target-system patch tooling so each Linux runner can evaluate its
  # corresponding target architecture without cross-arch requirements.
  patchedProxmoxNixosModules =
    let
      mkPatchedModules =
        patchSystem:
        let
          pkgs = inputs.nixpkgs.legacyPackages.${patchSystem};
        in
        import "${
          pkgs.applyPatches {
            name = "proxmox-nixos-source-patched";
            src = inputs.proxmox-nixos.outPath;
            patches = [
              # PR #195: allow setting only `cpu.cputype` by making other CPU sub-options nullable/defaulted.
              # https://github.com/SaumonNet/proxmox-nixos/pull/195
              (pkgs.fetchpatch {
                url = "https://github.com/SaumonNet/proxmox-nixos/commit/dc7e3daff2527155c0d4d685a0ce88dfa6aff8a2.patch";
                hash = "sha256-vvlKTzsYKFuukwJTPmSsOrKawL/Tu01yekQRbBopVIU=";
              })
              # PR #196: stop defaulting `vga.clipboard` to "vnc" (set null by default for migration compatibility).
              # https://github.com/SaumonNet/proxmox-nixos/pull/196
              (pkgs.fetchpatch {
                url = "https://github.com/SaumonNet/proxmox-nixos/commit/0ebf346501f6b5c93f9c37537d296cd2187aaf78.patch";
                hash = "sha256-JCYAL0dusUjLejj4TF2lw4PWxOi/ZOXMEJTUEM/UXUA=";
              })
            ];
          }
        }/modules";
      patchSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
    in
    builtins.listToAttrs (
      map (patchSystem: {
        name = patchSystem;
        value = mkPatchedModules patchSystem;
      }) patchSystems
    );
  mkPatchedProxmoxNixosModules =
    targetSystem:
    if builtins.hasAttr targetSystem patchedProxmoxNixosModules then
      builtins.getAttr targetSystem patchedProxmoxNixosModules
    else
      throw "Unsupported patch system for proxmox modules: ${targetSystem}";
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
      ]
      ++ nixpkgsInput.lib.optionals withHome [
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
            pkgs = nixpkgsInput.legacyPackages.${platform};
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
            (mkPatchedProxmoxNixosModules platform).declarative-vms
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

  mkBM =
    {
      mkHost,
      name,
      virtPlatform,
      ...
    }@args:
    let
      hostArgs = removeAttrs (args // { hostname = args.hostname or name; }) [
        "mkHost"
        "name"
        "virtPlatform"
      ];
      cfg = mkHost hostArgs;
      localName = "local-${name}vm";
      localCfg = builtins.tryEval (
        cfg.extendModules {
          modules = [
            {
              virtualisation.vmVariant.virtualisation = mkLocalVmVariantVirtualisation virtPlatform;
            }
          ];
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
        withHome = false;
        extraModules =
          extraModules
          ++ [
            (mkPatchedProxmoxNixosModules platform).proxmox-ve

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
                  (
                    final: prev:
                    let
                      # Work around proxmox-nixos ISO upload failures caused by
                      # Crypt::OpenSSL::RSA 0.35 (`illegal or unsupported padding mode`).
                      # Keep this until upstream PR #225 lands and is consumed here.
                      basePerl540 = prev.pve-common.perlModule;
                      patchedPerl540 = basePerl540.override {
                        overrides = _: {
                          CryptOpenSSLRSA = basePerl540.pkgs.CryptOpenSSLRSA.overrideAttrs (_: {
                            version = "0.33";
                            src = prev.fetchurl {
                              url = "mirror://cpan/authors/id/T/TO/TODDR/Crypt-OpenSSL-RSA-0.33.tar.gz";
                              hash = "sha256-vb5jD21vVAMldGrZmXcnKshmT/gb0Z8K2rptb0Xv2GQ=";
                            };
                          });
                        };
                      };
                      patchedAuthenpam = prev.authenpam.override {
                        perl540 = patchedPerl540;
                      };
                      patchedFindbin = prev.findbin.override {
                        perl540 = patchedPerl540;
                      };
                      patchedMimebase32 = prev.mimebase32.override {
                        perl540 = patchedPerl540;
                      };
                      patchedMimebase64 = prev.mimebase64.override {
                        perl540 = patchedPerl540;
                      };
                      patchedNetsubnet = prev.netsubnet.override {
                        perl540 = patchedPerl540;
                      };
                      patchedPosixstrptime = prev.posixstrptime.override {
                        perl540 = patchedPerl540;
                      };
                      patchedTermreadline = prev.termreadline.override {
                        perl540 = patchedPerl540;
                      };
                      patchedUuid = prev.uuid.override {
                        perl540 = patchedPerl540;
                      };
                      patchedPveApiClient = prev.pve-apiclient.override {
                        perl540 = patchedPerl540;
                      };
                      patchedPveRs = prev.pve-rs.override {
                        perl540 = patchedPerl540;
                      };
                      patchedPveRados2 = prev.pve-rados2.override {
                        perl540 = patchedPerl540;
                      };
                      patchedPveQemu = prev.pve-qemu.override {
                        perl540 = patchedPerl540;
                      };
                      patchedPveGuestCommon = prev.pve-guest-common.override {
                        perl540 = patchedPerl540;
                      };
                      patchedPveContainer = prev.pve-container.override {
                        perl540 = patchedPerl540;
                      };
                      patchedPveDocs = prev.pve-docs.override {
                        perl540 = patchedPerl540;
                      };
                      patchedPveHttpServer = prev.pve-http-server.override {
                        perl540 = patchedPerl540;
                      };
                      patchedPveCommon = prev.pve-common.override {
                        perl540 = patchedPerl540;
                        mimebase32 = patchedMimebase32;
                        mimebase64 = patchedMimebase64;
                      };
                      patchedPveAccessControl = prev.pve-access-control.override {
                        perl540 = patchedPerl540;
                        authenpam = patchedAuthenpam;
                        pve-common = patchedPveCommon;
                      };
                      patchedPveCluster = prev.pve-cluster.override {
                        perl540 = patchedPerl540;
                        pve-access-control = patchedPveAccessControl;
                        pve-apiclient = patchedPveApiClient;
                        pve-rs = patchedPveRs;
                      };
                      patchedPveNetwork = prev.pve-network.override {
                        perl540 = patchedPerl540;
                        netsubnet = patchedNetsubnet;
                        uuid = patchedUuid;
                        pve-access-control = patchedPveAccessControl;
                        pve-common = patchedPveCommon;
                        pve-cluster = patchedPveCluster;
                        pve-rs = patchedPveRs;
                      };
                      patchedPveFirewall = prev.pve-firewall.override {
                        perl540 = patchedPerl540;
                        pve-access-control = patchedPveAccessControl;
                        pve-cluster = patchedPveCluster;
                        pve-network = patchedPveNetwork;
                        pve-rs = patchedPveRs;
                      };
                      patchedPveStorage = prev.pve-storage.override {
                        perl540 = patchedPerl540;
                        posixstrptime = patchedPosixstrptime;
                        pve-cluster = patchedPveCluster;
                        pve-rados2 = patchedPveRados2;
                        pve-qemu = patchedPveQemu;
                      };
                      patchedPveQemuServer = prev.pve-qemu-server.override {
                        perl540 = patchedPerl540;
                        findbin = patchedFindbin;
                        termreadline = patchedTermreadline;
                        uuid = patchedUuid;
                        pve-firewall = patchedPveFirewall;
                        pve-qemu = patchedPveQemu;
                      };
                      patchedPveHaManager = prev.pve-ha-manager.override {
                        perl540 = patchedPerl540;
                        pve-container = patchedPveContainer;
                        pve-firewall = patchedPveFirewall;
                        pve-guest-common = patchedPveGuestCommon;
                        pve-qemu-server = patchedPveQemuServer;
                        pve-storage = patchedPveStorage;
                        pve-qemu = patchedPveQemu;
                      };
                      patchedPveManager =
                        (prev.pve-manager.override {
                          perl540 = patchedPerl540;
                          pve-docs = patchedPveDocs;
                          pve-ha-manager = patchedPveHaManager;
                          pve-http-server = patchedPveHttpServer;
                          pve-network = patchedPveNetwork;
                          pve-qemu = patchedPveQemu;
                        }).overrideAttrs
                          (old: {
                            patches = (old.patches or [ ]) ++ [
                              ./patches/pve-manager-disable-subscription-popup.patch
                            ];
                          });
                    in
                    {
                      perl540 = patchedPerl540;
                      authenpam = patchedAuthenpam;
                      findbin = patchedFindbin;
                      mimebase32 = patchedMimebase32;
                      mimebase64 = patchedMimebase64;
                      netsubnet = patchedNetsubnet;
                      posixstrptime = patchedPosixstrptime;
                      termreadline = patchedTermreadline;
                      uuid = patchedUuid;
                      pve-apiclient = patchedPveApiClient;
                      pve-common = patchedPveCommon;
                      pve-rs = patchedPveRs;
                      pve-rados2 = patchedPveRados2;
                      pve-qemu = patchedPveQemu;
                      pve-guest-common = patchedPveGuestCommon;
                      pve-container = patchedPveContainer;
                      pve-docs = patchedPveDocs;
                      pve-http-server = patchedPveHttpServer;
                      pve-access-control = patchedPveAccessControl;
                      pve-cluster = patchedPveCluster;
                      pve-network = patchedPveNetwork;
                      pve-firewall = patchedPveFirewall;
                      pve-storage = patchedPveStorage;
                      pve-qemu-server = patchedPveQemuServer;
                      pve-ha-manager = patchedPveHaManager;
                      pve-manager = patchedPveManager;
                      proxmox-ve = prev.proxmox-ve.override {
                        pve-access-control = patchedPveAccessControl;
                        pve-cluster = patchedPveCluster;
                        pve-container = patchedPveContainer;
                        pve-firewall = patchedPveFirewall;
                        pve-ha-manager = patchedPveHaManager;
                        pve-manager = patchedPveManager;
                        pve-qemu-server = patchedPveQemuServer;
                        pve-storage = patchedPveStorage;
                      };
                    }
                  )
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
        inputs.sops-nix.nixosModules.sops

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
        # If we ever add macOS VMs, thread isVM here and compute accordingly.
        upsShutdownDelaySeconds = upsShutdownDelaySeconds false;
      };
      modules = [
        inputs.nix-homebrew.darwinModules.nix-homebrew
        inputs.sops-nix.darwinModules.sops
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
  inherit mkVmHostPkgs;
}
