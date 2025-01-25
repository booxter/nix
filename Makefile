inputs-update:
	nix flake update

#linux-build:
#	nix run .#darwinVM

darwin-build:
	nix build .#darwinConfigurations.ihrachys-macpro.config.system.build.toplevel

darwin-switch:
	nix run nix-darwin -- switch --flake .#ihrachys-macpro

home-build:
	nix run nixpkgs#home-manager -- build --flake .

home-switch:
	nix run nixpkgs#home-manager -- switch --flake .
