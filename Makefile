# TODO: generalize to reuse code for similar targets

# Define common args
ARGS = -L --show-trace
inputs-update:
	nix flake update

########### local interactive vms
linuxvm:
	nix run .#linuxVM $(ARGS)

nvm:
	nix run .#nVM $(ARGS)

########### darwin build targets
darwin-build:
	nix build .#darwinConfigurations.mmini.config.system.build.toplevel $(ARGS)

darwin-build-mlt:
	nix build .#darwinConfigurations.ihrachyshka-mlt.config.system.build.toplevel $(ARGS)

darwin-switch:
	sudo nix run nix-darwin -- switch --flake .#mmini $(ARGS)

darwin-switch-mlt:
	sudo nix run nix-darwin -- switch --flake .#ihrachyshka-mlt $(ARGS)

########### home manager targets
HM_ARGS = -b backup
home-build:
	nix run nixpkgs#home-manager -- build --flake . $(ARGS)

home-build-mlt:
	nix run nixpkgs#home-manager -- build --flake .#${USER}@ihrachyshka-mlt $(ARGS)

home-build-nvcloud:
	nix run nixpkgs#home-manager -- build --flake .#${USER}@nv $(ARGS)

home-switch:
	nix run nixpkgs#home-manager -- switch --flake . $(ARGS) $(HM_ARGS)

home-switch-mlt:
	nix run nixpkgs#home-manager -- switch --flake .#${USER}@ihrachyshka-mlt $(ARGS) $(HM_ARGS)

home-switch-nv:
	nix run nixpkgs#home-manager -- switch --flake .#${USER}@nv $(ARGS) $(HM_ARGS)

############# raspberry pi targets
pi-image:
	nix build .#nixosConfigurations.pi5.config.system.build.sdImage -o pi5.sd
