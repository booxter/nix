pkgs: {
  jinjanator = pkgs.callPackage ./jinjanator { };

  ssh-ticket = pkgs.callPackage ./ssh-ticket { };
}
