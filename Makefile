.DEFAULT_GOAL := help
.PHONY: help nixos darwin linux-home darwin-home check

ARGS = -L --show-trace
USERNAME ?= ihrachyshka

define home-targets-for-system
nix eval --json --apply 'hc: builtins.mapAttrs (_: v: v.activationPackage.drvAttrs.system) hc' .#homeConfigurations \
	| jq -r 'to_entries[] | select(.value=="$(1)") | .key' \
	| sed 's/^$(USERNAME)@//'
endef

REMOTE ?= true
LOCAL_LOCAL_BUILDERS = $(shell nix run --quiet --option builders '' .#get-local-builders -- --local)

define builder-opts
$(if $(filter false,$(REMOTE)),--option builders '$(LOCAL_LOCAL_BUILDERS)',)
endef

define maybe-nom-build
if command -v nom >/dev/null 2>&1; then \
	nom build $(1) $(ARGS); \
	else \
	nix build $(1) $(ARGS); \
	fi
endef

define config-hosts
nix eval --json $(1) --apply builtins.attrNames | jq -r '.[]'
endef

define require-what-and-list-hosts
if [ "x$(WHAT)" = "x" ]; then \
	echo "Usage: make $@ WHAT=host [REMOTE=false]"; \
	echo; \
	echo "Available $(1) hosts:"; \
	printf '%s\n' "$$known"; \
	exit 1; \
	fi;
endef

define require-known-host
if ! printf '%s\n' "$$known" | grep -Fxq "$(2)"; then \
	echo "Unknown $(1) host: $(WHAT)"; \
	echo; \
	echo "Available $(1) hosts:"; \
	printf '%s\n' "$$known"; \
	exit 1; \
	fi;
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

		$(call maybe-nom-build,$(call builder-opts) .#homeConfigurations.$(USERNAME)@$(TARGET).activationPackage)
endef

help:
	@echo "Available targets:"
	@echo "  make nixos WHAT=<host> [REMOTE=false]"
	@echo "  make darwin WHAT=<host> [REMOTE=false]"
	@echo "  make check [WHAT=<check-name>] [REMOTE=false]"
	@echo "  make linux-home TARGET=<profile> [USERNAME=<name>] [REMOTE=false]"
	@echo "  make darwin-home TARGET=<profile> [USERNAME=<name>] [REMOTE=false]"

nixos:
	@known="$$($(call config-hosts,.#nixosConfigurations))"; \
	$(call require-what-and-list-hosts,nixos) \
	resolved="$(WHAT)"; \
	if ! printf '%s\n' "$$known" | grep -Fxq "$$resolved"; then \
		for candidate in "prox-$(WHAT)vm" "local-$(WHAT)vm"; do \
			if printf '%s\n' "$$known" | grep -Fxq "$$candidate"; then \
				resolved="$$candidate"; \
				break; \
			fi; \
		done; \
	fi; \
	$(call require-known-host,nixos,$$resolved) \
	$(call maybe-nom-build,$(call builder-opts) ".#nixosConfigurations.$$resolved.config.system.build.toplevel")

darwin:
	@known="$$($(call config-hosts,.#darwinConfigurations))"; \
	$(call require-what-and-list-hosts,darwin) \
	$(call require-known-host,darwin,$(WHAT)) \
	$(call maybe-nom-build,$(call builder-opts) ".#darwinConfigurations.$(WHAT).system")

linux-home:
	$(call standalone-home-build-action,linux,x86_64-linux)

darwin-home:
	$(call standalone-home-build-action,darwin,aarch64-darwin)

check:
	@system="$$(nix eval --impure --raw --expr builtins.currentSystem)"; \
	check_system="$$system"; \
	case "$$system" in \
		*-darwin) check_system="$${system%-darwin}-linux" ;; \
	esac; \
	known_native="$$(nix eval --json ".#checks.$$system" --apply builtins.attrNames | jq -r '.[]')"; \
	known_linux="$$known_native"; \
	if [ "$$check_system" != "$$system" ]; then \
		known_linux="$$(nix eval --json ".#checks.$$check_system" --apply builtins.attrNames | jq -r '.[]')"; \
	fi; \
	if [ "x$(WHAT)" = "x" ]; then \
		nix flake check $(call builder-opts) $(ARGS); \
		exit $$?; \
	fi; \
	selected_system="$$system"; \
	if printf '%s\n' "$$known_native" | grep -Fxq "$(WHAT)"; then \
		selected_system="$$system"; \
	elif [ "$$check_system" != "$$system" ] && printf '%s\n' "$$known_linux" | grep -Fxq "$(WHAT)"; then \
		selected_system="$$check_system"; \
	else \
		echo "Unknown check: $(WHAT)"; \
		echo; \
		echo "Available checks:"; \
		{ printf '%s\n' "$$known_native"; printf '%s\n' "$$known_linux"; } | awk 'NF' | LC_ALL=C sort -u; \
		exit 1; \
	fi; \
	$(call maybe-nom-build,$(call builder-opts) ".#checks.$$selected_system.$(WHAT)")
