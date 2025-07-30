# Inspirations:
# - https://github.com/wimpysworld/nix-config/ for general structure
{
  description = "booxter Nix* flake configs";

  # raspberrypi5 cachix
  nixConfig = {
    extra-substituters = [
      "https://nixos-raspberrypi.cachix.org"
    ];
    extra-trusted-public-keys = [
      "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI="
    ];
  };

  inputs = {
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nixpkgs-master.url = "github:NixOS/nixpkgs/master";
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    # TODO: Experiment with this
    #nix-darwin.url = "github:booxter/nix-darwin/launchd-use-path-state-to-wait-for-path";
    nix-darwin.url = "github:nix-darwin/nix-darwin/master";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";

    nix-homebrew.url = "github:zhaofengli/nix-homebrew";
    homebrew-core = {
      url = "github:homebrew/homebrew-core";
      flake = false;
    };
    homebrew-cask = {
      url = "github:homebrew/homebrew-cask";
      flake = false;
    };

    nix-rosetta-builder.url = "github:cpick/nix-rosetta-builder";
    home-manager.url = "github:nix-community/home-manager/master";
    nixvim.url = "github:nix-community/nixvim";
    nur.url = "github:nix-community/NUR";
    nixos-raspberrypi.url = "github:nvmd/nixos-raspberrypi/main";

    nixpkgs-netbootxyz.url = "github:booxter/nixpkgs/netbootxyz-update";
  };

  outputs = inputs@{ self, ... }:
  let
    inherit (self) outputs;
    stateVersion = "25.11";
    helper = import ./lib { inherit inputs outputs stateVersion; };
  in
  {
    # home-manager build --flake . -L
    # home-manager switch -b backup --flake .
    # nix run nixpkgs#home-manager -- switch -b backup --flake .
    homeConfigurations = {
      # mmini
      ihrachyshka = helper.mkHome {
        platform = "aarch64-darwin";
        isDesktop = true;
        isPrivate = true;
      };
      # nv laptop
      ihrachyshka-mlt = helper.mkHome {
        platform = "aarch64-darwin";
        isDesktop = true;
        isPrivate = false;
      };
      # nv vms
      ihrachyshka-nvcloud = helper.mkHome {
        platform = "x86_64-linux";
        isDesktop = false;
        isPrivate = false;
      };
    };

    #nix run nix-darwin -- switch --flake .
    #nix build .#darwinConfigurations.{hostname}.config.system.build.toplevel
    darwinConfigurations = {
      mmini = helper.mkDarwin {
        hostname = "mmini";
        platform = "aarch64-darwin";
        isPrivate = true;
      };
      ihrachyshka-mlt = helper.mkDarwin {
        hostname = "ihrachyshka-mlt";
        platform = "aarch64-darwin";
        isPrivate = false;
      };
    };

    # Custom packages and modifications, exported as overlays
    overlays = import ./overlays { inherit inputs; };

    # Custom packages; acessible via 'nix build', 'nix shell', etc
    packages = helper.forAllSystems (system: import ./pkgs inputs.nixpkgs.legacyPackages.${system});

    # Formatter for .nix files, available via 'nix fmt'
    formatter = helper.forAllSystems (system: inputs.nixpkgs.legacyPackages.${system}.nixfmt-rfc-style);

    ## adopted from https://www.tweag.io/blog/2023-02-09-nixos-vm-on-macos/
    nixosModules.base = { pkgs, ... }: {
      system.stateVersion = "25.11";

      nix = {
        package = pkgs.lix;
        settings = {
          # Share config with darwin module?
          experimental-features = "nix-command flakes";
          trusted-users = [ "@admin" ];
        };
      };

      users.mutableUsers = false;
      users.users.ihrachyshka = {
        extraGroups = ["wheel" "users"];
        group = "ihrachyshka";
        isNormalUser = true;
        # TODO: separate authorizations between private and non-private VMs
        openssh.authorizedKeys.keys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILF2Ga7NLRUkAqv6B4GDya40U1mQalWo8XOhEhOPF3zW ihrachyshka@Mac.lan"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHt25mSiJLQjx2JECMuhTZEV6rlrOYk3CT2cUEdXAoYs ihrachyshka@ihrachyshka-mlt"
        ];
      };
      users.groups.ihrachyshka = {};
      security.sudo.wheelNeedsPassword = false;

      environment.enableAllTerminfo = true;

      services.openssh.enable = true;
    };

    nixosModules.vm-resources = { ... }: {
      virtualisation.vmVariant.virtualisation = {
        cores = 4;
        memorySize = 4096; # 4GB
      };
    };

    nixosModules.vm = { ... }: let
      hostPkgs = (import inputs.nixpkgs { system = "aarch64-darwin"; });
    in {
      virtualisation.vmVariant.virtualisation = {
        host.pkgs = hostPkgs;
      };
    };

    # TODO: deduplicate
    nixosConfigurations = {
      pi5 = inputs.nixos-raspberrypi.lib.nixosSystem {
        specialArgs = inputs;

        system = "aarch64-linux";
        modules = [
          self.nixosModules.base

          {
            imports = with inputs.nixos-raspberrypi.nixosModules; [
              sd-image
              raspberry-pi-5.base
              raspberry-pi-5.display-vc4
              raspberry-pi-5.bluetooth
            ];
          }

          ({ config, pkgs, ... }: {
            nixpkgs = {
              overlays = [
                outputs.overlays.additions
                outputs.overlays.modifications
                outputs.overlays.unstable-packages
                outputs.overlays.master-packages
              ];
            };
          })

          ({ config, pkgs, ... }: {
            system.nixos.tags = let
              cfg = config.boot.loader.raspberryPi;
            in [
              "raspberry-pi-${cfg.variant}"
              cfg.bootloader
              config.boot.kernelPackages.kernel.version
            ];

            networking = {
              hostName = "pi5";
              interfaces.end0 = {
                ipv4.addresses = [{
                  address = "192.168.1.1";
                  prefixLength = 16;
                }];
              };
              defaultGateway = {
                address = "192.168.0.1";
                interface = "end0";
              };
              nameservers = [
                "192.168.0.1"
              ];
            };

            environment.systemPackages = with pkgs; [
              dig
              git
              lm_sensors
            ];

            # TODO: enable ipv6
            # TODO: use secret management for internal info?
            services.dnsmasq = {
              enable = true;
              resolveLocalQueries = true;
              settings = {
                interface = "end0";
                dhcp-authoritative = true;
                dhcp-rapid-commit = true;

                dhcp-range = [ "192.168.10.1,192.168.20.255" ];

                listen-address = ["192.168.1.1"];

                dhcp-option = [
                  "option:router,192.168.0.1"
                  "option:dns-server,192.168.1.1"
                ];

                server = [
                  "192.168.0.1"
                ];

                domain-needed = true;

                host-record = [
                  "egress,192.168.0.1"
                  "dhcp,192.168.1.1"
                ];

                # TODO: parametrize, eg.: https://github.com/kradalby/dotfiles/blob/6bae60204e1caab84262b2b1b7be013eeec80547/machines/dev.ldn/dnsmasq.nix
                dhcp-host = [
                  # infra
                  "7c:b7:7b:04:05:99,mdx,192.168.10.100" # MDX-8

                  # clients (wifi)
                  "76:90:da:3c:46:db,mmini,192.168.11.1"
                  "36:95:f3:6f:a7:f7,ihrachyshka-mlt,192.168.11.2"

                  # lab
                  "78:2d:7e:24:2d:f9,sw-lab,192.168.15.1" # switch
                  "78:72:64:43:9c:3f,nas-lab,192.168.15.2" # asustor
                ];

                enable-tftp = true;
                tftp-root = "/var/lib/dnsmasq/tftp";

                # Note: disable Secure Boot in BIOS
                dhcp-boot = [
                  "netboot.xyz.efi"
                ];
              };
            };
            networking.firewall.allowedUDPPorts = [
              53 # DNS
              67 # DHCP
              69 # TFTP
            ];
            systemd.tmpfiles.rules = [
              "L+ /var/lib/dnsmasq/tftp/netboot.xyz.efi - - - - ${pkgs.netbootxyz-efi}"
            ];

            users.users.root = {
              hashedPassword = "$y$j9T$oyigtat.5hqUofV6.n.2A1$.46cDAUbypufD8lYiEF66MIfm6v528vah7/zBUcQJt.";
              openssh.authorizedKeys.keys = [
                "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILF2Ga7NLRUkAqv6B4GDya40U1mQalWo8XOhEhOPF3zW ihrachyshka@Mac.lan"
              ];
            };

            users.users.ihrachyshka = {
              isNormalUser = true;
              extraGroups = [ "wheel" "users" ];
              openssh.authorizedKeys.keys = [
                "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILF2Ga7NLRUkAqv6B4GDya40U1mQalWo8XOhEhOPF3zW ihrachyshka@Mac.lan"
              ];
            };
            security.sudo.wheelNeedsPassword = false;

            environment.enableAllTerminfo = true;
            services.openssh.enable = true;

            nixpkgs.hostPlatform = inputs.nixpkgs.lib.mkDefault "aarch64-linux";
          })
        ];
      };
      linuxVM = inputs.nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        modules = [
          self.nixosModules.base
          self.nixosModules.vm-resources
          self.nixosModules.vm

          ({ pkgs, ... }: {
            # use zsh in the VM since it's meant for interactive use
            programs.zsh.enable = true;
            users.defaultUserShell = pkgs.zsh;

            # auto-login on tty
            services.getty.autologinUser = "ihrachyshka";
            virtualisation.vmVariant.virtualisation.graphics = false;
          })

          # TODO: combine home management with helpers.*?
          inputs.home-manager.nixosModules.home-manager
          {
            home-manager.extraSpecialArgs = {
              inherit
                inputs
                outputs
                stateVersion
                ;
              username = "ihrachyshka";
              isPrivate = true;
              isDesktop = false;
            };
            home-manager.useUserPackages = true;
            home-manager.users.ihrachyshka = import ./home-manager;
          }
        ];
      };

      nVM = inputs.nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        modules = [
          self.nixosModules.base
          self.nixosModules.vm-resources
          self.nixosModules.vm

          ({ ... }: {
            virtualisation.vmVariant.virtualisation = {
              cores = inputs.nixpkgs.lib.mkForce 8;
              memorySize = inputs.nixpkgs.lib.mkForce (4096 * 4); # 16GB
              diskSize = 100 * 1024; # 100GB
            };
          })

          ({ ... }: {
            virtualisation.vmVariant.virtualisation.forwardPorts = [
              {
                from = "host";
                guest.port = 22;
                host.port = 11110;
              }
            ];
          })

          ({ ... }: {
            virtualisation.docker = {
              enable = true;
            };
            users.users."ihrachyshka".extraGroups = [ "docker" ];
          })

          ({ pkgs, ... }: {
            # use zsh in the VM since it's meant for interactive use
            programs.zsh.enable = true;
            users.defaultUserShell = pkgs.zsh;

            # auto-login on tty
            services.getty.autologinUser = "ihrachyshka";
            virtualisation.vmVariant.virtualisation.graphics = false;
          })

          # TODO: combine home management with helpers.*?
          inputs.home-manager.nixosModules.home-manager
          {
            home-manager.extraSpecialArgs = {
              inherit
                inputs
                outputs
                stateVersion
                ;
              username = "ihrachyshka";
              isPrivate = false;
              isDesktop = false;
            };
            home-manager.useUserPackages = true;
            home-manager.users.ihrachyshka = import ./home-manager;
          }
        ];
      };
    };

    linuxVM = self.nixosConfigurations.linuxVM.config.system.build.vm;
    nVM = self.nixosConfigurations.nVM.config.system.build.vm;
  };
}
