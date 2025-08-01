# Inspirations:
# - https://github.com/wimpysworld/nix-config/ for general structure
{
  description = "booxter Nix* flake configs";

  # TODO: how to enable for a particular build only?
  # raspberrypi5 cachix
  #nixConfig = {
  #  extra-substituters = [
  #    "https://nixos-raspberrypi.cachix.org"
  #  ];
  #  extra-trusted-public-keys = [
  #    "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI="
  #  ];
  #};

  inputs = {
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nixpkgs-master.url = "github:NixOS/nixpkgs/master";
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

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

    home-manager.url = "github:nix-community/home-manager/master";
    nixvim.url = "github:nix-community/nixvim";
    nur.url = "github:nix-community/NUR";
    nixos-raspberrypi.url = "github:nvmd/nixos-raspberrypi/main";

    nixpkgs-netbootxyz.url = "github:booxter/nixpkgs/netbootxyz-update";
  };

  outputs = inputs@{ self, ... }:
  let
    inherit (self) outputs;
    username = "ihrachyshka";
    helper = import ./lib { inherit inputs outputs username; };
  in
  {
    homeConfigurations = {
      # personal mac mini
      "${username}@mmini" = helper.mkHome {
        stateVersion = "25.11";
        platform = "aarch64-darwin";
        isDesktop = true;
      };
      # nv laptop
      "${username}@ihrachyshka-mlt" = helper.mkHome {
        stateVersion = "25.11";
        platform = "aarch64-darwin";
        isDesktop = true;
        isWork = true;
      };
      # nv dev env
      "${username}@nv" = helper.mkHome {
        stateVersion = "25.11";
        platform = "x86_64-linux";
        isWork = true;
      };
    };

    darwinConfigurations = {
      mmini = helper.mkDarwin {
        stateVersion = 5;
        hostname = "mmini";
        platform = "aarch64-darwin";
        isDesktop = true;
      };
      ihrachyshka-mlt = helper.mkDarwin {
        stateVersion = 5;
        hostname = "ihrachyshka-mlt";
        platform = "aarch64-darwin";
        isDesktop = true;
        isWork = true;
      };
    };

    ## adopted from https://www.tweag.io/blog/2023-02-09-nixos-vm-on-macos/
    nixosModules.base = { ... }: {
      system.stateVersion = "25.11";

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
    };

    # TODO: deduplicate
    nixosConfigurations = {
      pi5 = inputs.nixos-raspberrypi.lib.nixosSystem {
        specialArgs = inputs;

        system = "aarch64-linux";
        modules = [
          ./common
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

            nixpkgs.hostPlatform = inputs.nixpkgs.lib.mkDefault "aarch64-linux";
          })
        ];
      };

      linuxVM = helper.mkNixos {
        stateVersion = "25.11";
        hostname = "linuxvm";
        platform = "aarch64-linux";
        virtPlatform = "aarch64-darwin";

        isVM = true;
        sshPort = 10000;

        extraModules = [
          ({ ... }: {
            virtualisation.vmVariant.virtualisation = {
              cores = 4;
              memorySize = 4 * 1024; # 4GB
            };
          })
        ];
      };

      nVM = helper.mkNixos {
        stateVersion = "25.11";
        hostname = "nvm";
        platform = "aarch64-linux";
        virtPlatform = "aarch64-darwin";

        isWork = true;
        isVM = true;
        sshPort = 10001;

        extraModules = [
          ({ ... }: {
            virtualisation.vmVariant.virtualisation = {
              cores = 8;
              memorySize = 16 * 1024; # 16GB
              diskSize = 100 * 1024; # 100GB
            };
          })
        ];
      };
    };

    linuxVM = self.nixosConfigurations.linuxVM.config.system.build.vm;
    nVM = self.nixosConfigurations.nVM.config.system.build.vm;

    overlays = import ./overlays { inherit inputs; };
    packages = helper.forAllSystems (system: import ./pkgs inputs.nixpkgs.legacyPackages.${system});
    formatter = helper.forAllSystems (system: inputs.nixpkgs.legacyPackages.${system}.nixfmt-rfc-style);
  };
}
