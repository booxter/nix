deploy:
	darwin-rebuild --keep-failed --verbose --show-trace switch --flake .#macpro

update:
	nix flake update

linux:
	sudo nix run .#darwinVM
