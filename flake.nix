# Inspirations:
# - https://github.com/wimpysworld/nix-config/ for general structure
{
  description = "booxter Nix* flake configs";

  # maybe not a good idea to follow? Measure the storage diff.
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

    nix-darwin.url = "github:LnL7/nix-darwin";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";

    home-manager.url = "github:nix-community/home-manager/master";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    nixvim.url = "github:nix-community/nixvim";
    nixvim.inputs.nixpkgs.follows = "nixpkgs";

    nur.url = "github:nix-community/NUR";
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
      "ihrachys@ihrachys-macpro" = helper.mkHome {
        hostname = "ihrachys-macpro";
        platform = "aarch64-darwin";
      };
      "ec2-user" = helper.mkHome {
        hostname = "ilab-ec2";
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

    # TODO: migrate to new scheme
    ## adopted from https://www.tweag.io/blog/2023-02-09-nixos-vm-on-macos/
    #nixosModules.base = { pkgs, ... }: {
    #  system.stateVersion = "25.05";

    #  services.getty.autologinUser = "${username}";

    #  users.mutableUsers = false;
    #  users.users.${username} = {
    #    extraGroups = ["wheel"];
    #    group = "${username}";
    #    isNormalUser = true;
    #    openssh.authorizedKeys.keys = [
    #      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA0W1oVd2GMoSwXHVQMb6v4e3rIMVe9/pr/PcsHg+Uz3 ihrachys@ihrachys-macpro"
    #    ];
    #  };
    #  users.groups.${username} = {};
    #  security.sudo.wheelNeedsPassword = false;

    #  environment.systemPackages = with pkgs; [
    #    dig
    #  ];

    #  services.openssh.enable = true;
    #};

    #nixosModules.vm = { ... }: {
    #  virtualisation.vmVariant.virtualisation = {
    #    host.pkgs = inputs.nixpkgs.legacyPackages.aarch64-darwin;

    #    # Make VM output to the terminal instead of a separate window
    #    graphics = false;

    #    # qemu.networkingOptions = inputs.nixpkgs.lib.mkForce [
    #    #     "-netdev vmnet-bridged,id=vmnet,ifname=en0"
    #    #     "-device virtio-net-pci,netdev=vmnet"
    #    # ];
    #  };

    #  # a workaround until slirp dns is fixed on macos:
    #  # https://github.com/utmapp/UTM/issues/2353
    #  # Note: the same workaround is applied to linux-builder in nixpkgs.
    #  networking.nameservers = [ "8.8.8.8" ];
    #};

    #nixosConfigurations = {
    #  linuxVM = inputs.nixpkgs.lib.nixosSystem rec {
    #    system = "aarch64-linux";
    #    pkgs = mkPkgs system;
    #    specialArgs = {
    #      inherit username;
    #    };
    #    modules = [
    #      self.nixosModules.base
    #      self.nixosModules.vm
    #    ] ++ (globalModulesLinux { inherit system username; });
    #  };
    #};

    #packages.aarch64-darwin.linuxVM = self.nixosConfigurations.linuxVM.config.system.build.vm;
  };
}
