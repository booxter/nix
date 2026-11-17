pkgs: {
  jinjanator = pkgs.callPackage ./jinjanator { };

  # Wrap nixpkgs page so it uses the Home Manager nixvim package as nvim.
  page = pkgs.callPackage ./page { };

}
