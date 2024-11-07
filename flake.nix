{
  description = "my work flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    nixpkgs-master.url = "github:NixOS/nixpkgs/master";

    # https://github.com/NixOS/nixpkgs/pull/350384
    nixpkgs-firefox.url = "github:booxter/nixpkgs/firefox-for-darwin";

    # https://github.com/NixOS/nixpkgs/pull/352493
    #nixpkgs-thunderbird.url = "github:booxter/nixpkgs/thunderbird-132-darwin";
    nixpkgs-thunderbird.url = "github:booxter/nixpkgs/thunder-try-latest-with-staging";

    # https://github.com/NixOS/nixpkgs/pull/348045
    nixpkgs-sioyek.url = "github:b-fein/nixpkgs/sioyek-fix-darwin-build";

    # https://github.com/insanum/gcalcli/pull/813
    nixpkgs-gcalcli.url = "github:booxter/nixpkgs/gcalcli-with-empty-searh-support";

    # TODO: post PR to nixpkgs
    nixpkgs-cb_thunderlink-native.url = "github:booxter/nixpkgs/cb_thunderlink-native";

    nixpkgs-2405.url = "github:NixOS/nixpkgs/release-24.05";

    nix-darwin.url = "github:LnL7/nix-darwin";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";

    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    nixvim.url = "github:nix-community/nixvim";
    nixvim.inputs.nixpkgs.follows = "nixpkgs";

    nur.url = "github:nix-community/NUR";

    system-manager.url = "github:numtide/system-manager";
    system-manager.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs@{ self, ... }:
  let
    username = "ihrachys";
    mkPkgs = system:
      import inputs.nixpkgs {
        inherit system;
        config = { allowUnfree = true; };
        overlays = [
          inputs.nur.overlay
          (final: prev: {
            inherit (inputs.nixpkgs-sioyek.legacyPackages.${prev.system})
              sioyek;
          })
          (final: prev: {
            inherit (inputs.nixpkgs-master.legacyPackages.${prev.system})
              rpm;
          })
          (final: prev: {
            inherit (inputs.nixpkgs-firefox.legacyPackages.${prev.system})
              firefox-unwrapped;
          })
          (final: prev: {
            inherit (inputs.nixpkgs-gcalcli.legacyPackages.${prev.system})
              gcalcli;
          })
          (final: prev: {
            inherit (inputs.nixpkgs-thunderbird.legacyPackages.${prev.system})
              thunderbird-unwrapped;
          })
          (final: prev: {
            inherit (inputs.nixpkgs-2405.legacyPackages.${prev.system})
              # go1.21 was dropped since 24.11
              go_1_21 gopls gomodifytags gore gotests;
          })
          (final: prev: {
            inherit (inputs.nixpkgs-cb_thunderlink-native.legacyPackages.${prev.system})
              cb_thunderlink-native;
          })
          (final: prev: {
            myemacs = import ./modules/myemacs { pkgs = prev; };
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
    globalModules = { username }: [
      (mkHome username [
        ./modules/home-manager
        inputs.nixvim.homeManagerModules.nixvim
      ])
    ];
    globalModulesMacos = { system, username }: globalModules { inherit username; } ++ [
      {
        system.configurationRevision = self.rev or self.dirtyRev or null;
      }
      ./modules/darwin
      (home-manager system).darwinModules.home-manager
    ];
    globalModulesSystemManager = { system, username }: globalModules { inherit username; } ++ [
      ./modules/system-manager
      (home-manager system).nixosModules.home-manager
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
        modules = (globalModulesMacos { inherit system username; }) ++ [
          ./hosts/macpro/configuration.nix
        ];
      };
    };

    # TODO: this is still broken; haven't figured out home-manager integration yet
    systemConfigs.default = let
      system = "x86_64-linux";
    in inputs.system-manager.lib.makeSystemConfig {
      extraSpecialArgs = { inherit username; };
      modules = (globalModulesSystemManager { inherit system username; });
    };
  };
}
