{
  description = "my work flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    # https://github.com/NixOS/nixpkgs/issues/349148
    nixpkgs-telegram.url = "github:NixOS/nixpkgs/b69de56fac8c2b6f8fd27f2eca01dcda8e0a4221";

    # https://github.com/NixOS/nixpkgs/pull/350384
    nixpkgs-firefox-thunderbird.url = "github:booxter/nixpkgs/firefox-for-darwin";

    # rpm: https://github.com/NixOS/nixpkgs/pull/346967
    nixpkgs-rpm.url = "github:reckenrode/nixpkgs/push-vvywqpsumluy";

    # https://github.com/NixOS/nixpkgs/pull/348045
    nixpkgs-sioyek.url = "github:b-fein/nixpkgs/sioyek-fix-darwin-build";

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
            inherit (inputs.nixpkgs-rpm.legacyPackages.${prev.system})
              rpm;
          })
          (final: prev: {
            inherit (inputs.nixpkgs-sioyek.legacyPackages.${prev.system})
              sioyek;
          })
          (final: prev: {
            inherit (inputs.nixpkgs-telegram.legacyPackages.${prev.system})
              telegram-desktop;
          })
          (final: prev: {
            inherit (inputs.nixpkgs-firefox-thunderbird.legacyPackages.${prev.system})
              firefox-unwrapped firefox-beta-unwrapped firefox-devedition-unwrapped firefox-esr-128-unwrapped
              thunderbird-unwrapped thunderbird-115-unwrapped thunderbird-128-unwrapped;
          })
          (final: prev: {
            emacs29-pgtk = prev.emacs29-pgtk.overrideAttrs (old: {
              patches =
                (old.patches or [])
                ++ [
                    # Fix OS window role (needed for window managers like yabai)
                    (prev.fetchpatch {
                      url = "https://raw.githubusercontent.com/d12frosted/homebrew-emacs-plus/master/patches/emacs-28/fix-window-role.patch";
                      sha256 = "sha256-+z/KfsBm1lvZTZNiMbxzXQGRTjkCFO4QPlEK35upjsE=";
                    })
                    # Use poll instead of select to get file descriptors
                    (prev.fetchpatch {
                      url = "https://raw.githubusercontent.com/d12frosted/homebrew-emacs-plus/master/patches/emacs-29/poll.patch";
                      sha256 = "sha256-jN9MlD8/ZrnLuP2/HUXXEVVd6A+aRZNYFdZF8ReJGfY=";
                    })
                    # Enable rounded window with no decoration
                    (prev.fetchpatch {
                      url = "https://raw.githubusercontent.com/d12frosted/homebrew-emacs-plus/master/patches/emacs-29/round-undecorated-frame.patch";
                      sha256 = "sha256-uYIxNTyfbprx5mCqMNFVrBcLeo+8e21qmBE3lpcnd+4=";
                    })
                    # Make Emacs aware of OS-level light/dark mode
                    (prev.fetchpatch {
                      url = "https://raw.githubusercontent.com/d12frosted/homebrew-emacs-plus/master/patches/emacs-28/system-appearance.patch";
                      sha256 = "sha256-oM6fXdXCWVcBnNrzXmF0ZMdp8j0pzkLE66WteeCutv8=";
                    })
                    # no-frame-refocus-cocoa, not sure if I need it but it's included in the plus build patches set
                    (prev.fetchpatch {
                      url = "https://raw.githubusercontent.com/d12frosted/homebrew-emacs-plus/master/patches/emacs-28/no-frame-refocus-cocoa.patch";
                      sha256 = "sha256-QLGplGoRpM4qgrIAJIbVJJsa4xj34axwT3LiWt++j/c=";
                    })
                ];
            });
          })
          (final: prev: {
            inherit (inputs.nixpkgs-firefox-thunderbird.legacyPackages.${prev.system})
              firefox-unwrapped firefox-beta-unwrapped firefox-devedition-unwrapped firefox-esr-128-unwrapped
              thunderbird-unwrapped thunderbird-115-unwrapped thunderbird-128-unwrapped;
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
