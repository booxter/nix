{ inputs, ... }:
{
  # This one brings our custom packages from the 'pkgs' directory
  additions = final: _prev: import ../pkgs final.pkgs;

  # This one contains whatever you want to overlay
  # You can change versions, add patches, set compilation flags, anything really.
  # https://nixos.wiki/wiki/Overlays
  modifications = _final: prev: {
    inherit (import inputs.nixpkgs-arcanist { inherit (prev) system; }) arcanist;
    inherit (import inputs.nixpkgs-mailsend-go { inherit (prev) system; }) mailsend-go;
    inherit (import inputs.nixpkgs-cb_thunderlink-native { inherit (prev) system; }) cb_thunderlink-native;
    inherit (import inputs.nixpkgs-ollama { inherit (prev) system; }) ollama;
    inherit (import inputs.nixpkgs-element { inherit (prev) system; }) element-desktop;
    # https://github.com/NixOS/nixpkgs/pull/384794
    inherit (import inputs.nixpkgs-master { inherit (prev) system; }) gitFull;
    flox = inputs.flox.packages.${prev.system}.default;
    nixpkgs-review = (import inputs.nixpkgs { inherit (prev) system; }).nixpkgs-review.override { withNom = true; };
  };

  # When applied, the unstable nixpkgs set (declared in the flake inputs) will
  # be accessible through 'pkgs.unstable'
  unstable-packages = final: _prev: {
    unstable = import inputs.nixpkgs-unstable {
      inherit (final) system;
      config.allowUnfree = true;
    };
  };

  master-packages = final: _prev: {
    master = import inputs.nixpkgs-master {
      inherit (final) system;
      config.allowUnfree = true;
    };
  };
}
