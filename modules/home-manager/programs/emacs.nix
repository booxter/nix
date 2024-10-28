{ pkgs, ...}: with pkgs; {
  enable = true;
  package = emacs29-pgtk;
}
