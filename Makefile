.DEFAULT_GOAL := help
.PHONY: help nixos darwin check check-nixos

ARGS = -L --show-trace
NH_ARGS = --print-build-logs --show-trace

REMOTE ?= true
LOCAL_LOCAL_BUILDERS = $(shell nix run --quiet --option builders '' .#get-local-builders -- --local)

define builder-opts
$(if $(filter false,$(REMOTE)),--option builders '$(LOCAL_LOCAL_BUILDERS)',)
endef

define nh-builder-opts
$(if $(filter false,$(REMOTE)),--builders '$(LOCAL_LOCAL_BUILDERS)',)
endef

define run-nh
nix shell $(call builder-opts) --inputs-from . nixpkgs#nh -c nh $(1)
endef

define nh-config-build
$(call run-nh,$(1) build $(call nh-builder-opts) --hostname "$(2)" $(NH_ARGS) ".#")
endef

define nom-build
nix shell $(call builder-opts) --inputs-from . nixpkgs#nix-output-monitor -c nom build $(call builder-opts) $(1) $(ARGS)
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

help:
	@echo "Available targets:"
	@echo "  make nixos WHAT=<host> [REMOTE=false]"
	@echo "  make darwin WHAT=<host> [REMOTE=false]"
	@echo "  make check [WHAT=<check-name>] [REMOTE=false]"
	@echo "  make check-nixos [WHAT=<nixos-check-name>] [REMOTE=false]"

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
	$(call nh-config-build,os,$$resolved)

darwin:
	@known="$$($(call config-hosts,.#darwinConfigurations))"; \
	$(call require-what-and-list-hosts,darwin) \
	$(call require-known-host,darwin,$(WHAT)) \
	$(call nh-config-build,darwin,$(WHAT))

check:
	@system="$$(nix eval --impure --raw --expr builtins.currentSystem)"; \
	known_native="$$(nix eval --json ".#checks.$$system" --apply builtins.attrNames | jq -r '.[]')"; \
	nixos_system="$$system"; \
	case "$$system" in \
		*-darwin) nixos_system="$${system%-darwin}-linux" ;; \
	esac; \
	known_nixos="$$(nix eval --json ".#nixosTests.$$nixos_system" --apply builtins.attrNames | jq -r '.[]')"; \
	if [ "x$(WHAT)" = "x" ]; then \
		if [ -z "$$known_native" ]; then \
			echo "No checks for $$system."; \
			exit 0; \
		fi; \
		for check_name in $$known_native; do \
			echo "Running $$check_name on $$system..."; \
			$(call nom-build,".#checks.$$system.$$check_name") || exit $$?; \
		done; \
		exit 0; \
	fi; \
	if ! printf '%s\n' "$$known_native" | grep -Fxq "$(WHAT)"; then \
		echo "Unknown check: $(WHAT)"; \
		echo; \
		echo "Available checks for $$system:"; \
		printf '%s\n' "$$known_native"; \
		if printf '%s\n' "$$known_nixos" | grep -Fxq "$(WHAT)"; then \
			echo; \
			echo "Hint: use make check-nixos WHAT=$(WHAT)"; \
		fi; \
		exit 1; \
	fi; \
	$(call nom-build,".#checks.$$system.$(WHAT)")

check-nixos:
	@system="$$(nix eval --impure --raw --expr builtins.currentSystem)"; \
	check_system="$$system"; \
	case "$$system" in \
		*-darwin) check_system="$${system%-darwin}-linux" ;; \
	esac; \
	nixos_checks="$$(nix eval --json ".#nixosTests.$$check_system" --apply builtins.attrNames | jq -r '.[]')"; \
	if [ "x$(WHAT)" = "x" ]; then \
		if [ -z "$$nixos_checks" ]; then \
			echo "No nixos checks for $$check_system."; \
			exit 0; \
		fi; \
		for check_name in $$nixos_checks; do \
			echo "Running $$check_name on $$check_system..."; \
			$(call nom-build,".#nixosTests.$$check_system.$$check_name") || exit $$?; \
		done; \
		exit 0; \
	fi; \
	if ! printf '%s\n' "$$nixos_checks" | grep -Fxq "$(WHAT)"; then \
		echo "Unknown nixos check: $(WHAT)"; \
		echo; \
		echo "Available nixos checks for $$check_system:"; \
		printf '%s\n' "$$nixos_checks"; \
		exit 1; \
	fi; \
	$(call nom-build,".#nixosTests.$$check_system.$(WHAT)")
