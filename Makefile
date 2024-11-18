deploy:
	darwin-rebuild --keep-failed --verbose --show-trace switch --flake .#macpro

update:
	nix flake update

linux:
	nix build .#darwinVM
	sudo nix run .#darwinVM
