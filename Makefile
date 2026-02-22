# Define common args
.DEFAULT_GOAL := help

ARGS = -L --show-trace
USERNAME ?= ihrachyshka

NIX_OPTS = \
	--extra-experimental-features 'nix-command flakes'

NIXOS_CONFIGS = nix flake show --json 2>/dev/null | jq -r -c '.nixosConfigurations | keys[]'
VM_TYPES = $(NIXOS_CONFIGS) | grep '^$(1)-.*vm$$' | sed 's/vm$$//' | sed 's/^$(1)-//'

define home-targets-for-system
nix eval --json --apply 'hc: builtins.mapAttrs (_: v: v.activationPackage.drvAttrs.system) hc' .#homeConfigurations \
	| jq -r 'to_entries[] | select(.value=="$(1)") | .key' \
	| sed 's/^$(USERNAME)@//'
endef

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

define standalone-home-build-action
	@if [ "x$(TARGET)" = "x" ]; then \
		echo "Usage: make $@ TARGET=profile [USERNAME=<name>] [REMOTE=false]"; \
		echo; \
		echo "Available $(1) home profiles:"; \
		$(call home-targets-for-system,$(2)); \
		exit 1; \
	fi
	@if ! ($(call home-targets-for-system,$(2)) | grep -Fxq "$(TARGET)"); then \
		echo "Unknown $(1) home profile: $(TARGET)"; \
		echo; \
		echo "Available $(1) home profiles:"; \
		$(call home-targets-for-system,$(2)); \
		exit 1; \
	fi

	nix build $(call builder-opts) .#homeConfigurations.$(USERNAME)@$(TARGET).activationPackage $(ARGS)
endef

help:
	@echo "Available targets:"
	@echo "  make nixos-build-target WHAT=<host> [REMOTE=false]"
	@echo "  make darwin-build-target WHAT=<host> [REMOTE=false]"
	@echo "  make local-vm WHAT=<type>"
	@echo "  make linux-home-build-target TARGET=<profile> [USERNAME=<name>] [REMOTE=false]"
	@echo "  make darwin-home-build-target TARGET=<profile> [USERNAME=<name>] [REMOTE=false]"
	@echo "  make disko-install WHAT=<host> DEV=/dev/<disk>"

########### local vms
local-vm:
	$(call nix-vm-action,local,run,vm)

########### nixos vms
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

linux-home-build-target:
	$(call standalone-home-build-action,linux,x86_64-linux)

darwin-home-build-target:
	$(call standalone-home-build-action,darwin,aarch64-darwin)
