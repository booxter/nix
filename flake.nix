{
  description = "my work flake";

  nixConfig = {
    extra-trusted-substituters = ["https://cache.flox.dev"];
    extra-trusted-public-keys = ["flox-cache-public-1:7F4OyH7ZCnFhcze3fJdfyXYLQw/aV7GEed86nQ7IsOs="];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-24.11-darwin";
    nixpkgs-master.url = "github:NixOS/nixpkgs/master";

    # https://github.com/NixOS/nixpkgs/pull/350384
    nixpkgs-firefox.url = "github:booxter/nixpkgs/firefox-for-darwin";

    # https://github.com/NixOS/nixpkgs/pull/352493
    #nixpkgs-thunderbird.url = "github:booxter/nixpkgs/thunderbird-132-darwin";
    nixpkgs-thunderbird.url = "github:booxter/nixpkgs/thunder-try-latest-with-staging";

    # https://github.com/NixOS/nixpkgs/pull/348045
    nixpkgs-sioyek.url = "github:b-fein/nixpkgs/sioyek-fix-darwin-build";

    # https://github.com/NixOS/nixpkgs/pull/252383
    nixpkgs-mailsend-go.url = "github:jsoo1/nixpkgs/mailsend-go";

    # TODO: post PR to nixpkgs
    nixpkgs-cb_thunderlink-native.url = "github:booxter/nixpkgs/cb_thunderlink-native";

    nix-darwin.url = "github:LnL7/nix-darwin";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";

    home-manager.url = "github:nix-community/home-manager/release-24.11";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    nixvim.url = "github:nix-community/nixvim";
    nixvim.inputs.nixpkgs.follows = "nixpkgs";

    nur.url = "github:nix-community/NUR";

    flox.url = "github:flox/flox/main";
    flox.inputs.nixpkgs.follows = "nixpkgs";
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
          inputs.nur.overlay
          (final: prev: {
            inherit (importPkgs { pkgs = inputs.nixpkgs-sioyek; inherit system; })
              sioyek;
          })
          (final: prev: {
            inherit (importPkgs { pkgs = inputs.nixpkgs-firefox; inherit system; })
              firefox-unwrapped;
          })
          (final: prev: {
            inherit (importPkgs { pkgs = inputs.nixpkgs-thunderbird; inherit system; })
              thunderbird-unwrapped;
          })
          (final: prev: {
            inherit (importPkgs { pkgs = inputs.nixpkgs-cb_thunderlink-native; inherit system; })
              cb_thunderlink-native;
          })
          (final: prev: {
            inherit (importPkgs { pkgs = inputs.nixpkgs-mailsend-go; inherit system; })
              mailsend-go;
          })
          (final: prev: {
            flox = inputs.flox.packages.${system}.default;
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
              url = "https://github.com/nix-community/home-manager/pull/5801/commits/0165235ea1162346397e2b600899e130b96a0e22.patch";
              sha256 = "sha256-vSQFf4y7Nun1PB2msDdjOMadm/ejaX45OrM1vrXcYWE=";
            })
            (pkgs.fetchpatch {
              url = "https://github.com/nix-community/home-manager/pull/5801/commits/c200ff63c0f99c57fac96aac667fd50b5057aec7.patch";
              sha256 = "sha256-HVQ+ZhkyroSYEeXXD7/Jrv3CNYDHx24Jn+iQB34VzLQ=";
            })
            (pkgs.fetchpatch {
              url = "https://github.com/nix-community/home-manager/pull/5801/commits/3afb17e065dcb88cb4794a16a16d44573c0b76cf.patch";
              sha256 = "sha256-iu/W8eJ2bd6rXoolvuA4E8yDwDPGibraPxByXTUzXKk=";
            })
            (pkgs.fetchpatch {
              url = "https://github.com/nix-community/home-manager/pull/5801/commits/a2bbd84dc2eba1c19a84aa917c247fc73843a387.patch";
              sha256 = "sha256-lhsgTkk+5YqColAFS0Y4MBEPhIkMpuywTt7IdhE9QN4=";
            })
            (pkgs.fetchpatch {
              url = "https://github.com/nix-community/home-manager/pull/5801/commits/d58239f42b44d42b64e1c20e6b563a72dce729bc.patch";
              sha256 = "sha256-j/LBM/pEIi14H2PbAFQjUgWX0h8bd9hAXqyaG1m9uX4=";
            })

            # Support extensions for thunderbird profiles
            # https://github.com/nix-community/home-manager/pull/6033
            (pkgs.fetchpatch {
              url = "https://github.com/nix-community/home-manager/commit/4d680ee96fe1b698e75804cf655c365ea4ec5433.patch";
              sha256 = "sha256-17FaxrhHymgFrVE4hO5eAn7DesLZ6CBlettDfJC/ro4=";
            })
            # Support native hosts for thunderbird
            # TODO: post upstream
            (pkgs.fetchpatch {
              url = "https://github.com/booxter/home-manager/commit/61b7d5db483241dc6f11c36ef00202539e957480.patch";
              sha256 = "sha256-yfWd7jGjvQ4I83nzRrIyiXPLHbuP50wABSiCjoZgX0U=";
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
      system.stateVersion = "24.11";

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
