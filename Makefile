.DEFAULT_GOAL := help
.PHONY: help nixos nixos-eval darwin darwin-eval check check-nixos

ARGS = -L --show-trace
NH_ARGS = --print-build-logs --show-trace
LOCAL_OS := $(shell uname -s)

# Avoid comparing a result with a local generation from another platform.
nh-diff-args = $(if $(filter $(1),$(LOCAL_OS)),,--diff never)

define nh-config-build
nix shell --inputs-from . nixpkgs#nh -c nh $(1) build --hostname "$(2)" $(3) $(NH_ARGS) ".#"
endef

define config-hosts
nix eval --json $(1) --apply builtins.attrNames | jq -r '.[]'
endef

define require-what-and-list-hosts
if [ "x$(WHAT)" = "x" ]; then \
	echo "Usage: make $@ WHAT=host"; \
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
	@echo "  make nixos WHAT=<host>"
	@echo "  make nixos-eval WHAT=<host>"
	@echo "  make darwin WHAT=<host>"
	@echo "  make darwin-eval WHAT=<host>"
	@echo "  make check [WHAT=<check-name>]"
	@echo "  make check-nixos [WHAT=<nixos-check-name>]"

nixos:
	@known="$$($(call config-hosts,.#nixosConfigurations))"; \
	$(call require-what-and-list-hosts,nixos) \
	$(call require-known-host,nixos,$(WHAT)) \
	$(call nh-config-build,os,$(WHAT),$(call nh-diff-args,Linux))

nixos-eval:
	@known="$$($(call config-hosts,.#nixosConfigurations))"; \
	$(call require-what-and-list-hosts,nixos) \
	$(call require-known-host,nixos,$(WHAT)) \
	nix eval $(ARGS) ".#nixosConfigurations.$(WHAT).config.system.build.toplevel.drvPath"

darwin:
	@known="$$($(call config-hosts,.#darwinConfigurations))"; \
	$(call require-what-and-list-hosts,darwin) \
	$(call require-known-host,darwin,$(WHAT)) \
	$(call nh-config-build,darwin,$(WHAT),$(call nh-diff-args,Darwin))

darwin-eval:
	@known="$$($(call config-hosts,.#darwinConfigurations))"; \
	$(call require-what-and-list-hosts,darwin) \
	$(call require-known-host,darwin,$(WHAT)) \
	nix eval $(ARGS) ".#darwinConfigurations.$(WHAT).system.drvPath"

check:
	@WHAT="$(WHAT)" nix run --quiet .#run-check-target -- checks checks check

check-nixos:
	@WHAT="$(WHAT)" nix run --quiet .#run-check-target -- nixosTests "nixos checks" "nixos check"
