# TODO: generalize to reuse code for similar targets

# Define common args
ARGS = -L --show-trace
inputs-update:
	nix flake update

########### local interactive vms
linuxvm:
	nix run .#linuxVM $(ARGS)

nvm:
	nix run .#nVM $(ARGS)

########### darwin build targets
darwin-build:
	nix build .#darwinConfigurations.mmini.config.system.build.toplevel $(ARGS)

darwin-build-mlt:
	nix build .#darwinConfigurations.ihrachyshka-mlt.config.system.build.toplevel $(ARGS)

darwin-switch:
	sudo nix run nix-darwin -- switch --flake .#mmini $(ARGS)

darwin-switch-mlt:
	sudo nix run nix-darwin -- switch --flake .#ihrachyshka-mlt $(ARGS)

########### home manager targets
HM_ARGS = -b backup
home-build-nv:
	nix run nixpkgs#home-manager -- build --flake .#${USER}@nv $(ARGS)

home-switch-nv:
	nix run nixpkgs#home-manager -- switch --flake .#${USER}@nv $(ARGS) $(HM_ARGS)

############# raspberry pi targets
pi-image:
	nix build \
		--option extra-trusted-public-keys "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI=" \
		--option extra-substituters "https://nixos-raspberrypi.cachix.org?priority=50" \
	.#nixosConfigurations.pi5.config.system.build.sdImage -o pi5.sd $(ARGS)
