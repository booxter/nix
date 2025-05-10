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
    inherit (import inputs.nixpkgs-fromager { inherit (prev) system; }) fromager;
    inherit (import inputs.nixpkgs-zoom { inherit (prev) system; config.allowUnfree = true; }) zoom-us;
    flox = inputs.flox.packages.${prev.system}.default;
    nixpkgs-review = (import inputs.nixpkgs { inherit (prev) system; }).nixpkgs-review.override { withNom = true; };

    # TODO: remove when https://github.com/NixOS/nixpkgs/issues/400373 is merged
    python312 = prev.python312.override {
      packageOverrides = final: prev: {
        mocket = prev.mocket.overridePythonAttrs (oldAttrs: {
          disabledTests = oldAttrs.disabledTests ++ [
            "test_httprettish_httpx_session"
          ];
        });
      };
    };
    python312Packages = python312.pkgs;
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
