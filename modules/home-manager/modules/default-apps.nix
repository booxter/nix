# Adopted from https://github.com/ferrine/nix-darwin/blob/f6c90ff92b7723e461d88d3b508e218f0d38710d/nix/home/modules/fix-lsregister-macos.nix
# Changed to honor app paths with space characters.
{ lib, pkgs, ... }: {
  home.activation.default-apps = let
    lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister";
    xargs = "${pkgs.findutils}/bin/xargs -d '\\n'";
    grep = "${pkgs.gnugrep}/bin/grep";
    realpath = "${pkgs.coreutils}/bin/realpath";
    find = "${pkgs.findutils}/bin/find";
  in
    lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      # unregister all from the previous generation
      ${lsregister} -dump | ${grep} -oE '(/nix/store/.*\.app)' | ${xargs} ${lsregister} -f -u
      # refresh with new generation
      ${find} $(${realpath} $HOME/Applications/Home\ Manager\ Apps) -name '*.app' -exec ${realpath} {} \; | ${xargs} ${lsregister} -f
    '';
}
