# Define common args
.DEFAULT_GOAL := help

ARGS = -L --show-trace
HM_ARGS = -b backup
USERNAME ?= ihrachyshka

NIX_OPTS = \
	--extra-experimental-features 'nix-command flakes'

NIXOS_CONFIGS = nix flake show --json 2>/dev/null | jq -r -c '.nixosConfigurations | keys[]'
VM_TYPES = $(NIXOS_CONFIGS) | grep '^$(1)-.*vm$$' | sed 's/vm$$//' | sed 's/^$(1)-//'

REMOTE ?= true
LOCAL_LOCAL_BUILDERS := $(shell ./scripts/get-local-builders.sh --local)

define builder-opts
$(if $(filter false,$(REMOTE)),--option builders '$(LOCAL_LOCAL_BUILDERS)',)
endef

define nix-vm-action
	# $(1): VM prefix (local/prox)
	# $(2): nix command (run/build)
	# $(3): build output (vm/toplevel)
	@if [ "x$(WHAT)" = "x" ]; then \
		echo "Usage: make $@ WHAT=type"; echo; echo "Available vms:"; \
		$(call VM_TYPES,$(1)); \
		exit 1; \
	fi

	nix $(2) \
		$(call builder-opts) \
		.#nixosConfigurations.$(1)-$(WHAT)vm.config.system.build.$(3) $(ARGS)
endef

define nix-config-action
	# $(1): build target attribute path
	@if [ "x$(WHAT)" = "x" ]; then \
		echo "Usage: make $@ WHAT=host [REMOTE=false]"; \
		exit 1; \
	fi

	nix build $(call builder-opts) $(1) $(ARGS)
endef

help:
	@echo "Available targets:"
	@echo "  make nixos-build-target WHAT=<host> [REMOTE=false]"
	@echo "  make darwin-build-target WHAT=<host> [REMOTE=false]"
	@echo "  make local-vm WHAT=<type>"
	@echo "  make nixos-build-vm WHAT=<type>"
	@echo "  make home-build-nv [USERNAME=<name>]"
	@echo "  make home-switch-nv [USERNAME=<name>]"
	@echo "  make disko-install WHAT=<host> DEV=/dev/<disk>"

########### local vms
local-vm:
	$(call nix-vm-action,local,run,vm)

########### nixos vms
nixos-build-vm:
	$(call nix-vm-action,prox,build,vm)

########### nixos
nixos-build-target:
	$(call nix-config-action,.#nixosConfigurations.$(WHAT).config.system.build.toplevel)

disko-install:
	@if [ "x$(WHAT)" = "x" -o "x$(DEV)" = "x" ]; then \
		echo "Usage: make $@ WHAT=host DEV=/dev/XXX"; \
		exit 1; \
	fi
	sudo nix $(NIX_OPTS) run $(ARGS) \
		'github:nix-community/disko/latest#disko-install' -- --flake .#$(WHAT) --disk main $(DEV)

########### darwin
darwin-build-target:
	$(call nix-config-action,.#darwinConfigurations.$(WHAT).system)

########### standalone home-manager
home-build-nv:
	nix run nixpkgs#home-manager -- build --flake .#${USERNAME}@nv $(ARGS)

home-switch-nv:
	nix run nixpkgs#home-manager -- switch --flake .#${USERNAME}@nv $(ARGS) $(HM_ARGS)
