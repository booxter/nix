# Define common args
ARGS = -L --show-trace
HM_ARGS = -b backup

NIX_OPTS = \
	--extra-experimental-features 'nix-command flakes'

DEFAULT_CACHE_PRIORITY = 50

list-nixos-configs = nix flake show --json 2>/dev/null | jq -r -c '.nixosConfigurations | keys[]'
list-vm-types = $(list-nixos-configs) | grep '^$(1)-.*vm$$' | sed 's/vm$$//' | sed 's/^$(1)-//'

define nix-vm-action
	@if [ "x$(WHAT)" = "x" ]; then \
		echo "Usage: make $@ WHAT=type"; echo; echo "Available vms:"; \
		$(call list-vm-types,$(1)); \
		exit 1; \
	fi

	nix $(2) \
		$(VM_CACHE_OPTS) \
		.#nixosConfigurations.$(1)-$(WHAT)vm.config.system.build.$(3) $(ARGS)
endef

define nix-config-action
	@if [ "x$(WHAT)" = "x" ]; then \
		echo "Usage: make $@ WHAT=host"; \
		exit 1; \
	fi

	nix build $(1) $(2) $(ARGS)
endef

RPI_CACHE_OPTIONS = \
	--option extra-trusted-public-keys "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI=" \
	--option extra-substituters "https://nixos-raspberrypi.cachix.org?priority=$(DEFAULT_CACHE_PRIORITY)"

PROXMOX_CACHE_OPTIONS = \
	--option extra-trusted-public-keys "proxmox-nixos:D9RYSWpQQC/msZUWphOY2I5RLH5Dd6yQcaHIuug7dWM=" \
	--option extra-substituters "https://cache.saumon.network/proxmox-nixos?priority=$(DEFAULT_CACHE_PRIORITY)"

VM_CACHE_OPTS = \
	$(if $(filter pi5,$(WHAT)), $(RPI_CACHE_OPTIONS),) \
	$(if $(filter proxmox,$(WHAT)), $(PROXMOX_CACHE_OPTIONS),)

# Reused for host builds too (pi5 benefit from RPI cache, proxmox from Proxmox cache).
HOST_CACHE_OPTS = \
	$(if $(filter pi5,$(WHAT)), $(RPI_CACHE_OPTIONS),) \
	$(if $(filter prox%,$(WHAT)), $(PROXMOX_CACHE_OPTIONS),) \
	$(if $(filter prx%,$(WHAT)), $(PROXMOX_CACHE_OPTIONS),) \
	$(if $(filter nvws%,$(WHAT)), $(PROXMOX_CACHE_OPTIONS),)

# Also the default target (just call `make`)
inputs-update:
	nix flake update

########### local vms
local-vm:
	$(call nix-vm-action,local,run,vm)

build-local-vm:
	$(call nix-vm-action,local,build,vm)

########### ci vms
ci-vm:
	$(call nix-vm-action,ci,run,vm)

build-ci-vm:
	$(call nix-vm-action,ci,build,vm)

build-ci-vm-config:
	$(call nix-vm-action,ci,build,toplevel)

########### proxmox vms
prox-vm:
	@if [ "x$(WHAT)" = "x" ]; then \
		echo "Usage: make $@ WHAT=type WHERE=hv"; echo; echo "Available vms:"; \
		$(call list-vm-types,prox); \
		exit 1; \
	fi

	@if [ "x$(WHERE)" = "x" ]; then \
		echo "Usage: make $@ WHAT=type WHERE=hv"; \
		exit 1; \
	fi

	./scripts/push-vm-to-proxmox.sh $(WHERE) root priv/lab-$(WHERE) prox-$(WHAT)vm

########### nixos
nixos-build-target:
	$(call nix-config-action,$(HOST_CACHE_OPTS),.#nixosConfigurations.$(WHAT).config.system.build.toplevel)

nixos-build:
	nix build .#nixosConfigurations.$(shell hostname).config.system.build.toplevel $(ARGS)

nixos-switch:
	sudo nixos-rebuild switch --flake .#$(shell hostname) $(ARGS)

disko-install:
	@if [ "x$(WHAT)" = "x" -o "x$(DEV)" = "x" ]; then \
		echo "Usage: make $@ WHAT=host DEV=/dev/XXX"; \
		exit 1; \
	fi
	sudo nix $(NIX_OPTS) run $(ARGS) \
		$(if $(filter prx%,$(WHAT)), $(PROXMOX_CACHE_OPTIONS),) \
		'github:nix-community/disko/latest#disko-install' -- --flake .#$(WHAT) --disk main $(DEV)

########### darwin
darwin-build:
	nix build .#darwinConfigurations.$(shell hostname).config.system.build.toplevel $(ARGS)

darwin-build-target:
	$(call nix-config-action,.,.#darwinConfigurations.$(WHAT).system)

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