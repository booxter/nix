inputs-update:
	nix --extra-experimental-features 'nix-command flakes' flake update

#linux-build:
#	nix run .#darwinVM

darwin-build:
	nix --extra-experimental-features 'nix-command flakes' build .#darwinConfigurations.ihrachys-macpro.config.system.build.toplevel

darwin-switch:
	nix --extra-experimental-features 'nix-command flakes' run nix-darwin -- switch --flake .#ihrachys-macpro

home-build:
	nix --extra-experimental-features 'nix-command flakes' run nixpkgs#home-manager -- build --flake .

home-switch:
	nix --extra-experimental-features 'nix-command flakes' run nixpkgs#home-manager -- switch --flake . --show-trace
