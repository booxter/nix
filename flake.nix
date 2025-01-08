{
  description = "my work flake";

  nixConfig = {
    extra-trusted-substituters = ["https://cache.flox.dev"];
    extra-trusted-public-keys = ["flox-cache-public-1:7F4OyH7ZCnFhcze3fJdfyXYLQw/aV7GEed86nQ7IsOs="];
  };

  inputs = rec {
    nixpkgs-old.url = "github:NixOS/nixpkgs/nixpkgs-24.11-darwin";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nixpkgs-master.url = "github:NixOS/nixpkgs/master";

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

    flox.url = "github:flox/flox/main";
    # complains about older nix version not available otherwise
    flox.inputs.nixpkgs.follows = "nixpkgs-old";
  };

  outputs = inputs@{ self, ... }:
  let
    username = "ihrachys";
    importPkgs = { pkgs, system }: (import pkgs {
      inherit system;
      config = { allowUnfree = true; };
    });
    mkPkgs = system:
      import inputs.nixpkgs {
        inherit system;
        config = { allowUnfree = true; };
        overlays = [
          inputs.nur.overlays.default
          (final: prev: {
            inherit (importPkgs { pkgs = inputs.nixpkgs-cb_thunderlink-native; inherit system; })
              cb_thunderlink-native;
          })
          (final: prev: {
            inherit (importPkgs { pkgs = inputs.nixpkgs-mailsend-go; inherit system; })
              mailsend-go;
          })
          (final: prev: {
            inherit (importPkgs { pkgs = inputs.nixpkgs-arcanist; inherit system; })
              arcanist;
          })
          (final: prev: {
            flox = inputs.flox.packages.${system}.default;
          })
          # Packages I care enough about to pull from master
          (final: prev: {
            inherit (importPkgs { pkgs = inputs.nixpkgs-master; inherit system; })
              firefox-unwrapped thunderbird-unwrapped podman-desktop;
          })
        ];
      };
    mkHome = username: modules: {
      home-manager = {
        useGlobalPkgs = true;
        useUserPackages = true;
        backupFileExtension = "backup";
        extraSpecialArgs = { inherit inputs username; };
        users."${username}".imports = modules;
      };
    };

    commonModules = { username, modules ? [] }: [
      (mkHome username ([
        ./modules/home-manager
        inputs.nixvim.homeManagerModules.nixvim
      ] ++ modules))
    ];

    globalModulesLinux = { system, username }: commonModules { inherit username; } ++ [
      {
        system.configurationRevision = self.rev or self.dirtyRev or null;
      }
      (home-manager system).nixosModules.home-manager
    ];

    globalModulesMacos = { system, username, modules }: commonModules { inherit modules username; } ++ [
      {
        system.configurationRevision = self.rev or self.dirtyRev or null;
      }
      (home-manager system).darwinModules.home-manager
      ./modules/darwin
    ];

    # local patches for stuff that I haven't merged upstream yet
    home-manager = system: with inputs; let
      src = let
        pkgs = mkPkgs system;
      in pkgs.applyPatches {
          name = "home-manager";
          src = inputs.home-manager;
          # TODO: is there a fetcher for a range of commits?..
          patches = [
            # Embed MOZ_* and other variables into launchd environment
            # https://github.com/nix-community/home-manager/pull/5801
            (pkgs.fetchpatch {
              url = "https://github.com/nix-community/home-manager/pull/5801/commits/db0eae1c7981bebefed443a0377aff4026f539eb.patch";
              sha256 = "sha256-UbnthN5zIj3h/7w0+af9LfJ9+ynPRBKSRDBizbPmO6c=";
            })
            (pkgs.fetchpatch {
              url = "https://github.com/nix-community/home-manager/pull/5801/commits/6c52c6fab4b5a39182066181a22c689e371bb5df.patch";
              sha256 = "sha256-7mWsyaiGXiCLv++mIJEADTgm5HJNygwjGVz55f5aGP0=";
            })
            #(pkgs.fetchpatch {
            #  url = "https://github.com/nix-community/home-manager/pull/5801/commits/06196d929516a31b82d9b7b04e8ae49f51754bf1.patch";
            #  sha256 = "sha256-iu/W8eJ2bd6rXoolvuA4E8yDwDPGibraPxByXTUzXKk=";
            #})
            #(pkgs.fetchpatch {
            #  url = "https://github.com/nix-community/home-manager/pull/5801/commits/03d774740f1d8f92926641f756061612df3f7fcb.patch";
            #  sha256 = "sha256-rGwMFJmWF9N9ny+5lAkqAuwGAuAV0Yu4FMAOTCPDe2s=";
            #})
            #(pkgs.fetchpatch {
            #  url = "https://github.com/nix-community/home-manager/pull/5801/commits/24fc7dacf6b4aca2d5aeced58563f845ed6c9ca9.patch";
            #  sha256 = "sha256-t0apIUHaAWrWXHG4AnDQPdHE9qZHGqK7fWBicJXu/LI=";
            #})

            (pkgs.fetchpatch {
              url = "https://github.com/booxter/home-manager/commit/dbe54a48a0bc9942289f6a5d8a751ed3be065c81.patch";
              sha256 = "sha256-1xpGCqx0k9Aewmw3UNfjAfvKyF8pY6PSqZsRBCqE/gA=";
            })
            (pkgs.fetchpatch {
              url = "https://github.com/booxter/home-manager/commit/8bfa7b024b5b83274388f69ae448e93ddf532573.patch";
              sha256 = "sha256-rGwMFJmWF9N9ny+5lAkqAuwGAuAV0Yu4FMAOTCPDe2s=";
            })
            (pkgs.fetchpatch {
              url = "https://github.com/booxter/home-manager/commit/ff575b88f8320f37cc84c68f8acf687b647902a0.patch";
              sha256 = "sha256-t0apIUHaAWrWXHG4AnDQPdHE9qZHGqK7fWBicJXu/LI=";
            })

            # Support native hosts for thunderbird
            # TODO: post upstream
            (pkgs.fetchpatch {
              url = "https://github.com/booxter/home-manager/commit/34978ffd7b1393e0a30810c835144cd3b0fe0634.patch";
              sha256 = "sha256-eMGMDokOsotOD5/0ju9x4aBC8rNyYtdks4AIdw5epY0=";
            })
          ];
        };
      in
      nixpkgs.lib.fix (self: (import "${src}/flake.nix").outputs { inherit self nixpkgs; });
  in
  {
    darwinConfigurations = let
      system = "aarch64-darwin";
    in {
      macpro = inputs.nix-darwin.lib.darwinSystem rec {
        inherit system;
        pkgs = mkPkgs system;
        specialArgs = {
          inherit username;
        };
        modules = let
          additionalModules = [
            ./modules/home-manager/modules/git-sync.nix
            ./modules/home-manager/modules/thunderbird.nix
            ./modules/home-manager/modules/firefox.nix
            ./modules/home-manager/modules/kitty.nix
            ./modules/home-manager/modules/telegram.nix
            ./modules/home-manager/modules/default-apps.nix
          ];
        in
          (globalModulesMacos {
            inherit system username;
            modules = additionalModules;
          }) ++ [
            ./hosts/macpro/configuration.nix
        ];
      };
    };

    # adopted from https://www.tweag.io/blog/2023-02-09-nixos-vm-on-macos/
    nixosModules.base = { pkgs, ... }: {
      system.stateVersion = "25.05";

      services.getty.autologinUser = "${username}";

      users.mutableUsers = false;
      users.users.${username} = {
        extraGroups = ["wheel"];
        group = "${username}";
        isNormalUser = true;
        openssh.authorizedKeys.keys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA0W1oVd2GMoSwXHVQMb6v4e3rIMVe9/pr/PcsHg+Uz3 ihrachys@ihrachys-macpro"
        ];
      };
      users.groups.${username} = {};
      security.sudo.wheelNeedsPassword = false;

      environment.systemPackages = with pkgs; [
        dig
      ];

      services.openssh.enable = true;
    };

    nixosModules.vm = { ... }: {
      virtualisation.vmVariant.virtualisation = {
        host.pkgs = inputs.nixpkgs.legacyPackages.aarch64-darwin;

        # Make VM output to the terminal instead of a separate window
        graphics = false;

        # qemu.networkingOptions = inputs.nixpkgs.lib.mkForce [
        #     "-netdev vmnet-bridged,id=vmnet,ifname=en0"
        #     "-device virtio-net-pci,netdev=vmnet"
        # ];
      };

      # a workaround until slirp dns is fixed on macos:
      # https://github.com/utmapp/UTM/issues/2353
      # Note: the same workaround is applied to linux-builder in nixpkgs.
      networking.nameservers = [ "8.8.8.8" ];
    };

    nixosConfigurations = {
      darwinVM = inputs.nixpkgs.lib.nixosSystem rec {
        system = "aarch64-linux";
        pkgs = mkPkgs system;
        specialArgs = {
          inherit username;
        };
        modules = [
          self.nixosModules.base
          self.nixosModules.vm
        ] ++ (globalModulesLinux { inherit system username; });
      };
    };

    packages.aarch64-darwin.darwinVM = self.nixosConfigurations.darwinVM.config.system.build.vm;
  };
}
