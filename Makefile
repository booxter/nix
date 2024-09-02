deploy:
	darwin-rebuild --verbose --show-trace switch --flake .#macpro

update:
	nix flake update
