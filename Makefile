inputs-update:
	nix flake update

linux:
	nix run .#linuxVM -L --show-trace

linux-vbox:
	nix build .#nixosConfigurations.serviceVM.config.formats.virtualbox -L --show-trace

linux-vmware:
	nix build .#nixosConfigurations.serviceVM.config.formats.vmware -L --show-trace

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
