deploy:
	darwin-rebuild switch --flake .#macpro

update:
	nix flake update
