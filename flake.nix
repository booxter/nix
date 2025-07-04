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
      ihrachyshka = helper.mkHome {
        hostname = "mmini";
        platform = "aarch64-darwin";
      };
      ihrachyshka-mlt = helper.mkHome {
        hostname = "ihrachyshka-mlt";
        platform = "aarch64-darwin";
      };
    };

    #nix run nix-darwin -- switch --flake .
    #nix build .#darwinConfigurations.{hostname}.config.system.build.toplevel
    darwinConfigurations = {
      mmini = helper.mkDarwin {
        hostname = "mmini";
        platform = "aarch64-darwin";
      };
      ihrachyshka-mlt = helper.mkDarwin {
        hostname = "ihrachyshka-mlt";
        platform = "aarch64-darwin";
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

      programs.zsh.enable = true;
      users.defaultUserShell = pkgs.zsh;

      services.getty.autologinUser = "ihrachyshka";

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

    nixosModules.vm = { ... }: {
      virtualisation.vmVariant.virtualisation = {
        memorySize = 4096; # 4GB

        # Make VM output to the terminal instead of a separate window
        graphics = false;
      };
    };

    nixosConfigurations = {
      linuxVM = inputs.nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        modules = [
          self.nixosModules.base
          self.nixosModules.vm

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
              isDesktop = false;
            };
            home-manager.useUserPackages = true;
            home-manager.users.ihrachyshka = import ./home-manager;
          }
        ];
      };
    };

    linuxVM = self.nixosConfigurations.linuxVM.config.system.build.vm;
  };
}
