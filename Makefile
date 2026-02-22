# Define common args
.DEFAULT_GOAL := help

ARGS = -L --show-trace
USERNAME ?= ihrachyshka

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
	@echo "  make linux-home-build-target TARGET=<profile> [USERNAME=<name>] [REMOTE=false]"
	@echo "  make darwin-home-build-target TARGET=<profile> [USERNAME=<name>] [REMOTE=false]"

########### nixos vms
########### nixos
nixos-build-target:
	$(call nix-config-action,.#nixosConfigurations.$(WHAT).config.system.build.toplevel)

########### darwin
darwin-build-target:
	$(call nix-config-action,.#darwinConfigurations.$(WHAT).system)

linux-home-build-target:
	$(call standalone-home-build-action,linux,x86_64-linux)

darwin-home-build-target:
	$(call standalone-home-build-action,darwin,aarch64-darwin)
