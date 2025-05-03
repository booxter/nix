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

    # https://github.com/NixOS/nixpkgs/pull/252383
    nixpkgs-mailsend-go.url = "github:jsoo1/nixpkgs/mailsend-go";

    # TODO: post PR to nixpkgs
    nixpkgs-cb_thunderlink-native.url = "github:booxter/nixpkgs/cb_thunderlink-native";

    nixpkgs-libslirp.url = "github:booxter/nixpkgs/macos-remove-hack-for-dns-libslirp";

    nix-darwin.url = "github:booxter/nix-darwin/launchd-use-path-state-to-wait-for-path";

    nix-rosetta-builder.url = "github:cpick/nix-rosetta-builder";

    home-manager.url = "github:nix-community/home-manager/master";

    nixvim.url = "github:nix-community/nixvim";

    nur.url = "github:nix-community/NUR";

    flox.url = "github:flox/flox/v1.3.11";
  };

  outputs = inputs@{ self, ... }:
  let
    inherit (self) outputs;
    stateVersion = "25.05";
    helper = import ./lib { inherit inputs outputs stateVersion; };
  in
  {
    # home-manager build --flake . -L
    # home-manager switch -b backup --flake .
    # nix run nixpkgs#home-manager -- switch -b backup --flake .
    homeConfigurations = {
      "ihrachys" = helper.mkHome {
        hostname = "ihrachys-macpro";
        platform = "aarch64-darwin";
      };
      "ec2-user" = helper.mkHome {
        hostname = "ec2";
        username = "ec2-user";
        platform = "x86_64-linux";
      };
    };

    #nix run nix-darwin -- switch --flake .
    #nix build .#darwinConfigurations.{hostname}.config.system.build.toplevel
    darwinConfigurations = {
      ihrachys-macpro = helper.mkDarwin {
        hostname = "ihrachys-macpro";
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
      system.stateVersion = "25.05";

      services.getty.autologinUser = "ihrachys";

      users.mutableUsers = false;
      users.users.ihrachys = {
        extraGroups = ["wheel" "users"];
        group = "ihrachys";
        isNormalUser = true;
        openssh.authorizedKeys.keys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA0W1oVd2GMoSwXHVQMb6v4e3rIMVe9/pr/PcsHg+Uz3 ihrachys@ihrachys-macpro"
        ];
      };
      users.groups.ihrachys = {};
      security.sudo.wheelNeedsPassword = false;

      environment.systemPackages = with pkgs; [
        dig
      ];

      services.openssh.enable = true;
    };

    nixosModules.vm = { ... }: {
      virtualisation.vmVariant.virtualisation = {
        host.pkgs = inputs.nixpkgs-libslirp.legacyPackages.aarch64-darwin;

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
        ];
      };
    };

    linuxVM = self.nixosConfigurations.linuxVM.config.system.build.vm;
  };
}
