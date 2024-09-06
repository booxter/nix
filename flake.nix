{
  description = "my work flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nixpkgs_kitty_fix.url = "github:leiserfg/nixpkgs/fix-kitty-nerfont";

    nix-darwin.url = "github:LnL7/nix-darwin";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";

    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    nixvim.url = "github:nix-community/nixvim";
    nixvim.inputs.nixpkgs.follows = "nixpkgs";

    nur.url = "github:nix-community/NUR";

    emacs.url = "github:nix-community/emacs-overlay";
    emacs.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs@{ self, ... }:
  let
    mkPkgs = system:
      import inputs.nixpkgs {
        inherit system;
        config = { allowUnfree = true; };
        overlays = [
          inputs.nur.overlay
          inputs.emacs.overlay
          (final: prev: {
            inherit (inputs.nixpkgs_kitty_fix.legacyPackages.${prev.system})
              kitty;
          })
        ];
      };
    mkHome = username: modules: {
      home-manager = {
        useGlobalPkgs = true;
        useUserPackages = true;
        backupFileExtension = "backup";
        extraSpecialArgs = {inherit inputs username; };
        users."${username}".imports = modules;
      };
    };
    globalModules = { username }: [
      {
        system.configurationRevision = self.rev or self.dirtyRev or null;
      }
      (mkHome username [
        ./modules/home-manager
        inputs.nixvim.homeManagerModules.nixvim
      ])
    ];
    globalModulesMacos = { username }: globalModules { inherit username; } ++ [
      ./modules/darwin
      home-manager.darwinModules.home-manager
    ];
    home-manager = with inputs; let
        src = nixpkgs.legacyPackages."aarch64-darwin".applyPatches {
          name = "home-manager";
          src = inputs.home-manager;
          patches = [
            ./patches/0001-thunderbird-set-MOZ_-variables-for-legacy-profiles.i.patch
            ./patches/0002-firefox-set-MOZ_-variables-for-legacy-profiles.ini.patch
            ./patches/0003-darwin-Set-launchd.user.envVariables-from-home.sessi.patch
          ];
        };
      in
      nixpkgs.lib.fix (self: (import "${src}/flake.nix").outputs { inherit self nixpkgs; });
  in
  {
    darwinConfigurations = let
      username = "ihrachys";
    in {
      macpro = inputs.nix-darwin.lib.darwinSystem rec {
        system = "aarch64-darwin";
        pkgs = mkPkgs system;
        specialArgs = {
          inherit username;
        };
        modules = (globalModulesMacos { inherit username; }) ++ [
          ./hosts/macpro/configuration.nix
        ];
      };
    };
  };
}
