# Define common args
ARGS = -L --show-trace
HM_ARGS = -b backup

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

	nix run .#nixosConfigurations.$(WHAT)vm.config.system.build.vm $(ARGS)

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
	nix build \
		--option extra-trusted-public-keys "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI=" \
		--option extra-substituters "https://nixos-raspberrypi.cachix.org?priority=50" \
	.#nixosConfigurations.pi5.config.system.build.sdImage -o pi5.sd $(ARGS)
