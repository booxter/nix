inputs-update:
	nix flake update

linux:
	nix run .#linuxVM -L --show-trace

darwin-build:
	nix build .#darwinConfigurations.mmini.config.system.build.toplevel

darwin-switch:
	sudo nix run nix-darwin -- switch --flake .#mmini

home-build:
	nix run nixpkgs#home-manager -- build --flake .

home-switch:
	nix run nixpkgs#home-manager -- switch --flake . --show-trace
