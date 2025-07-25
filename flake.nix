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

  inputs = rec {
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nixpkgs-master.url = "github:NixOS/nixpkgs/master";

    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    # arcanist was removed:
    # https://github.com/NixOS/nixpkgs/commit/5ed483f0d79461c2c2d63b46ee62f77a37075bae
    nixpkgs-arcanist.url = "github:NixOS/nixpkgs/nixpkgs-24.05-darwin";

    nixpkgs-firefox-binary-wrapper.url = "github:booxter/nixpkgs/switch-firefox-to-binary-wrapper";

    # TODO: post PR to nixpkgs
    nixpkgs-cb_thunderlink-native.url = "github:booxter/nixpkgs/cb_thunderlink-native";

    # X11
    nixpkgs-awesome.url = "github:booxter/nixpkgs/awesome-darwin";
    nixpkgs-mesa-xephyr.url = "github:booxter/nixpkgs/mesa-darwin-libgl";
    nixpkgs-ted.url = "github:booxter/nixpkgs/ted-darwin";
    nixpkgs-xbill.url = "github:booxter/nixpkgs/xbill-fix-build";

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

    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-raspberrypi.url = "github:nvmd/nixos-raspberrypi/main";
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

    nixosModules.builder = { config, ... }: {
        boot.binfmt.emulatedSystems = ["aarch64-linux"];
        nix.settings = {
          extra-platforms = config.boot.binfmt.emulatedSystems;
          trusted-users = [ "@wheel" ];
        };
    };

    nixosModules.jellyfin = { pkgs, ... }: {
      services.jellyfin = {
        enable = true;
        openFirewall = true;
      };
      environment.systemPackages = [
        pkgs.jellyfin
        pkgs.jellyfin-web
        pkgs.jellyfin-ffmpeg
      ];
    };

    nixosModules.formats = { ... }: {
      imports = [
        inputs.nixos-generators.nixosModules.all-formats
      ];
      nixpkgs.hostPlatform = "x86_64-linux";
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

          ({ config, ... }: {
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
                  address = "10.0.0.10";
                  prefixLength = 24;
                }];
              };
              defaultGateway = {
                address = "10.0.0.1";
                interface = "end0";
              };
              nameservers = [
                "8.8.8.8"
              ];
            };

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

      # TODO: separate service configuration per VM; move to other files
      serviceVM = inputs.nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          self.nixosModules.base
          self.nixosModules.vm-resources
          self.nixosModules.formats

          ({ ... }: { networking.hostName = "service"; })
          self.nixosModules.jellyfin
        ];
      };

      builderVM = inputs.nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          self.nixosModules.base
          self.nixosModules.vm-resources
          self.nixosModules.formats

          ({ ... }: { networking.hostName = "builder"; })
          self.nixosModules.builder
        ];
      };
    };

    linuxVM = self.nixosConfigurations.linuxVM.config.system.build.vm;
    nVM = self.nixosConfigurations.nVM.config.system.build.vm;
  };
}
