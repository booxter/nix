# Inspirations:
# - https://github.com/wimpysworld/nix-config/ for general structure
{
  description = "booxter Nix* flake configs";

  inputs = rec {
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nixpkgs-master.url = "github:NixOS/nixpkgs/master";

    # We can control the base package set with this input alias
    nixpkgs = nixpkgs-unstable;

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
        openssh.authorizedKeys.keys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILF2Ga7NLRUkAqv6B4GDya40U1mQalWo8XOhEhOPF3zW ihrachyshka@Mac.lan"
        ];
      };
      users.groups.ihrachyshka = {};
      security.sudo.wheelNeedsPassword = false;

      environment.systemPackages = with pkgs; [
        dig
      ];

      services.openssh.enable = true;
    };

    nixosModules.rosetta = { ... }: {
      virtualisation.vmVariant.virtualisation = {
        rosetta.enable = true;
      };
    };

    nixosModules.vm-resources = { ... }: {
      virtualisation.vmVariant.virtualisation = {
        cores = 4;
        memorySize = 4096 * 4; # 16GB
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

    nixosConfigurations = {
      linuxVM = inputs.nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        modules = [
          self.nixosModules.base
          self.nixosModules.rosetta
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
        system = "x86_64-linux";
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
