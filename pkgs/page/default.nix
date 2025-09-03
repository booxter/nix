{
  lib,
  pkgs,
  neovim ? pkgs.neovim,
  ...
}:
pkgs.writeScriptBin "page" ''
  PATH=${neovim}/bin:$PATH exec ${lib.getExe pkgs.page}
''
