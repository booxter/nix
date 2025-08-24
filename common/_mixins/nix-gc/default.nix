{ lib, ... }:
rec {
  nix.gc = {
    automatic = true;
    options = "--delete-older-than 7d";
  };
  # then optimise the nix store an hour later
  nix.optimise.automatic = true;
}
