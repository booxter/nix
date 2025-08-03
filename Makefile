# Define common args
ARGS = -L --show-trace
HM_ARGS = -b backup

DEFAULT_CACHE_PRIORITY = 50

RPI_CACHE_OPTIONS = \
	--option extra-trusted-public-keys "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI=" \
	--option extra-substituters "https://nixos-raspberrypi.cachix.org?priority=$(DEFAULT_CACHE_PRIORITY)"

PROXMOX_CACHE_OPTIONS = \
	--option extra-trusted-public-keys "proxmox-nixos:D9RYSWpQQC/msZUWphOY2I5RLH5Dd6yQcaHIuug7dWM=" \
	--option extra-substituters "https://cache.saumon.network/proxmox-nixos?priority=$(DEFAULT_CACHE_PRIORITY)"

# Also the default target (just call `make`)
inputs-update:
	nix flake update

########### interactive vms
vm:
	@if [ "x$(WHAT)" = "x" ]; then\
		echo "Usage: make $@ WHAT=type"; echo; echo "Available vms:";\
	  nix flake show --json 2>/dev/null | jq -r -c '.nixosConfigurations | keys[]' | grep 'vm$$' | sed 's/vm$$//';\
	  exit 1;\
	fi

	nix run \
		$(if $(filter pi5,$(WHAT)), $(RPI_CACHE_OPTIONS),) \
		$(if $(filter proxmox,$(WHAT)), $(PROXMOX_CACHE_OPTIONS),) \
		.#nixosConfigurations.$(WHAT)vm.config.system.build.vm $(ARGS)

########### nixos
nixos-build:
	nix build .#nixosConfigurations.$(shell hostname).config.system.build.toplevel $(ARGS)

nixos-switch:
	sudo nixos-rebuild switch --flake .#$(shell hostname) $(ARGS)

########### darwin
darwin-build:
	nix build .#darwinConfigurations.$(shell hostname).config.system.build.toplevel $(ARGS)

darwin-switch:
	sudo nix run nix-darwin -- switch --flake .#$(shell hostname) $(ARGS)

########### standalone home-manager
home-build-nv:
	nix run nixpkgs#home-manager -- build --flake .#${USER}@nv $(ARGS)

home-switch-nv:
	nix run nixpkgs#home-manager -- switch --flake .#${USER}@nv $(ARGS) $(HM_ARGS)

############# raspberry pi
pi-image:
	nix build $(RPI_CACHE_OPTIONS) .#nixosConfigurations.pi5.config.system.build.sdImage -o pi5.sd $(ARGS)
