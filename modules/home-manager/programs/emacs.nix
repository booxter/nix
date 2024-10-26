{ pkgs, ...}: with pkgs; {
  enable = true;
  package = emacs29-pgtk;
  extraPackages = epkgs: [
    coreutils
    fd
    fontconfig
    ghostscript
    git
    gnugrep
    notmuch
    (ripgrep.override { withPCRE2 = true; })
    shellcheck
  ];
}

