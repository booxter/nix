deploy:
	darwin-rebuild --keep-failed --verbose --show-trace switch --flake .#macpro

update:
	nix flake update

linux:
	nix run .#darwinVM
