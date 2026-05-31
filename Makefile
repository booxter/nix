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

define run-check-target
@system="$$(nix eval --impure --raw --expr builtins.currentSystem)"; \
linux_system = "$$system"; \
case "$$system" in \
*-darwin) linux_system="$${system%-darwin}-linux" ;; \
esac; \
check_system = "$$system"; \
if [ "$(1)" = "nixosTests" ]; then \
check_system = "$$linux_system"; \
fi; \
checks = "$$(nix eval --json ".#$(1).$$check_system" --apply builtins.attrNames | jq -r '.[]')"; \
if [ "x$(WHAT)" = "x" ]; then \
if [ -z "$$checks" ]; then \
echo "No $(2) for $$check_system."; \
exit 0; \
fi; \
for check_name in $$checks; do \
echo "Running $$check_name on $$check_system..."; \
$(call nom-build,".#$(1).$$check_system.$$check_name") || exit $$?; \
done; \
exit 0; \
fi; \
if ! printf '%s\n' "$$checks" | grep -Fxq "$(WHAT)"; then \
echo "Unknown $(3): $(WHAT)"; \
echo; \
echo "Available $(2) for $$check_system:"; \
printf '%s\n' "$$checks"; \
if [ "$(1)" = "checks" ]; then \
nixos_checks = "$$(nix eval --json ".#nixosTests.$$linux_system" --apply builtins.attrNames | jq -r '.[]')"; \
if printf '%s\n' "$$nixos_checks" | grep -Fxq "$(WHAT)"; then \
echo; \
echo "Hint: use make check-nixos WHAT=$(WHAT)"; \
fi; \
fi; \
exit 1; \
fi; \
$(call nom-build,".#$(1).$$check_system.$(WHAT)")
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
	$(call run-check-target,checks,checks,check)

check-nixos:
	$(call run-check-target,nixosTests,nixos checks,nixos check)
