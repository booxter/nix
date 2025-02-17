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
    flox = inputs.flox.packages.${prev.system}.default;
    ollama = let
      pkgs = import inputs.nixpkgs { inherit (prev) system; };
    in pkgs.ollama.overrideAttrs (oldAttrs: {
      patches = [
        (pkgs.fetchpatch2 {
          url = "https://github.com/ollama/ollama/pull/8746/commits/fb801e1e1f4de9d295ae306278fb1040ad42ffde.patch?full_index=1";
          hash = "sha256-HstYCxtd2vlqIlffGxra82wUlFH7F98YFQs7CXdQ26Q=";
        })
        (pkgs.fetchpatch2 {
          url = "https://github.com/ollama/ollama/pull/8746/commits/dac0154f21c576e8dfc729f699ff18baa37181c4.patch?full_index=1";
          hash = "sha256-QqluubLyr5kxMJk9wnKP0PZHE733oq3fA/0gSGe78ak=";
        })
      ];
    });
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
