{
  description = "my work flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    # sdk: https://github.com/NixOS/nixpkgs/pull/346043
    # gcc: https://github.com/NixOS/nixpkgs/pull/346949
    # rpm: https://github.com/NixOS/nixpkgs/pull/346967
    nixpkgs-rpm.url = "github:booxter/nixpkgs/rpm-darwin";

    # https://github.com/NixOS/nixpkgs/pull/348370
    nixpkgs-heimdal.url = "github:booxter/nixpkgs/heimdal-darwin";

    nixpkgs-sioyek.url = "github:booxter/nixpkgs/sioyek";

    nixpkgs-podman-desktop.url = "github:booxter/nixpkgs/podman-desktop";

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
            inherit (inputs.nixpkgs-podman-desktop.legacyPackages.${prev.system})
              podman-desktop;
          })
          (final: prev: {
            inherit (inputs.nixpkgs-rpm.legacyPackages.${prev.system})
              rpm;
          })
          (final: prev: {
            inherit (inputs.nixpkgs-sioyek.legacyPackages.${prev.system})
              sioyek;
          })
          (final: prev: {
            inherit (inputs.nixpkgs-heimdal.legacyPackages.${prev.system})
              heimdal;
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
        src = (mkPkgs system).applyPatches {
          name = "home-manager";
          src = inputs.home-manager;
          patches = [
            ./patches/0001-thunderbird-set-MOZ_-variables-for-legacy-profiles.i.patch
            ./patches/0002-firefox-set-MOZ_-variables-for-legacy-profiles.ini.patch
            ./patches/0003-launchd-create-service-to-launchctl-setenv-for-all-s.patch
            ./patches/0004-Revert-firefox-fix-incorrect-condition.patch
            ./patches/0005-Revert-firefox-only-add-Version-2-on-non-darwin.patch
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
