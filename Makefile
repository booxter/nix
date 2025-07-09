inputs-update:
	nix flake update

linux:
	nix run .#linuxVM -L --show-trace

service-vbox:
	nix build .#nixosConfigurations.serviceVM.config.formats.virtualbox -L --show-trace

builder-vbox:
	nix build .#nixosConfigurations.builderVM.config.formats.virtualbox -L --show-trace

# TODO: generalize into a single target with parameters
darwin-build:
	nix build .#darwinConfigurations.mmini.config.system.build.toplevel

darwin-switch:
	sudo nix run nix-darwin -- switch --flake .#mmini

darwin-build-mlt:
	nix build .#darwinConfigurations.ihrachyshka-mlt.config.system.build.toplevel

darwin-switch-mlt:
	sudo nix run nix-darwin -- switch --flake .#ihrachyshka-mlt

home-build:
	nix run nixpkgs#home-manager -- build --flake .

home-switch:
	nix run nixpkgs#home-manager -- switch --flake . --show-trace

home-build-mlt:
	nix run nixpkgs#home-manager -- build --flake .#ihrachyshka-mlt

home-switch-mlt:
	nix run nixpkgs#home-manager -- switch --flake .#ihrachyshka-mlt --show-trace

home-build-nvcloud:
	nix run nixpkgs#home-manager -- build --flake .#ihrachyshka-nvcloud

home-switch-nvcloud:
	nix run nixpkgs#home-manager -- switch --flake .#ihrachyshka-nvcloud --show-trace
