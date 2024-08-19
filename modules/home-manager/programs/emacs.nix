{ pkgs, ...}: with pkgs; {
  enable = true;
  package = emacsMacport;
  extraPackages = epkgs: [
    coreutils
    fd
    fontconfig
    git
    gnugrep
    (ripgrep.override { withPCRE2 = true; })
    shellcheck
  ];
}

