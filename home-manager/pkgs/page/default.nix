{
  lib,
  pkgs,
  neovim ? pkgs.neovim,
  ...
}:
pkgs.writeShellScriptBin "page" ''
  PATH=${neovim}/bin:$PATH exec ${lib.getExe pkgs.page}
''
