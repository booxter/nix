.DEFAULT_GOAL := help
.PHONY: help nixos nixos-eval darwin darwin-eval check check-nixos

ARGS = -L --show-trace
NH_ARGS = --print-build-logs --show-trace
LOCAL_OS := $(shell uname -s)

# Avoid comparing a result with a local generation from another platform.
nh-diff-args = $(if $(filter $(1),$(LOCAL_OS)),,--diff never)

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
$(call run-nh,$(1) build $(call nh-builder-opts) --hostname "$(2)" $(3) $(NH_ARGS) ".#")
endef

define nom-build
nix shell $(call builder-opts) --inputs-from . nixpkgs#nix-output-monitor -c nom build $(call builder-opts) $(1) $(ARGS)
endef

define config-hosts
nix eval --json $(1) --apply builtins.attrNames | jq -r '.[]'
endef

define require-what-and-list-hosts
if [ "x$(WHAT)" = "x" ]; then \
	echo "Usage: make $@ WHAT=host$(2)"; \
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
	@echo "  make nixos-eval WHAT=<host>"
	@echo "  make darwin WHAT=<host> [REMOTE=false]"
	@echo "  make darwin-eval WHAT=<host>"
	@echo "  make check [WHAT=<check-name>] [REMOTE=false]"
	@echo "  make check-nixos [WHAT=<nixos-check-name>] [REMOTE=false]"

nixos:
	@known="$$($(call config-hosts,.#nixosConfigurations))"; \
	$(call require-what-and-list-hosts,nixos, [REMOTE=false]) \
	$(call require-known-host,nixos,$(WHAT)) \
	$(call nh-config-build,os,$(WHAT),$(call nh-diff-args,Linux))

nixos-eval:
	@known="$$($(call config-hosts,.#nixosConfigurations))"; \
	$(call require-what-and-list-hosts,nixos) \
	$(call require-known-host,nixos,$(WHAT)) \
	nix eval $(ARGS) ".#nixosConfigurations.$(WHAT).config.system.build.toplevel.drvPath"

darwin:
	@known="$$($(call config-hosts,.#darwinConfigurations))"; \
	$(call require-what-and-list-hosts,darwin, [REMOTE=false]) \
	$(call require-known-host,darwin,$(WHAT)) \
	$(call nh-config-build,darwin,$(WHAT),$(call nh-diff-args,Darwin))

darwin-eval:
	@known="$$($(call config-hosts,.#darwinConfigurations))"; \
	$(call require-what-and-list-hosts,darwin) \
	$(call require-known-host,darwin,$(WHAT)) \
	nix eval $(ARGS) ".#darwinConfigurations.$(WHAT).system.drvPath"

check:
	@WHAT="$(WHAT)" REMOTE="$(REMOTE)" nix run --quiet .#run-check-target -- checks checks check

check-nixos:
	@WHAT="$(WHAT)" REMOTE="$(REMOTE)" nix run --quiet .#run-check-target -- nixosTests "nixos checks" "nixos check"
