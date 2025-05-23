{ inputs, ... }:
{
  # This one brings our custom packages from the 'pkgs' directory
  additions = final: _prev: import ../pkgs final.pkgs;

  # This one contains whatever you want to overlay
  # You can change versions, add patches, set compilation flags, anything really.
  # https://nixos.wiki/wiki/Overlays
  modifications = _final: prev: rec {
    inherit (import inputs.nixpkgs-arcanist { inherit (prev) system; }) arcanist;
    inherit (import inputs.nixpkgs-mailsend-go { inherit (prev) system; }) mailsend-go;
    inherit (import inputs.nixpkgs-cb_thunderlink-native { inherit (prev) system; }) cb_thunderlink-native;
    inherit (import inputs.nixpkgs-firefox-binary-wrapper { inherit (prev) system; }) firefox;
    nixpkgs-review = (import inputs.nixpkgs { inherit (prev) system; }).nixpkgs-review.override { withNom = true; };

    # python312 = prev.python312.override {
    #   packageOverrides = final: prev: {
    #     XXX = prev.XXX.overridePythonAttrs (oldAttrs: {
    #       disabledTests = oldAttrs.disabledTests ++ [
    #       ];
    #     });
    #   };
    # };
    # python312Packages = python312.pkgs;
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
