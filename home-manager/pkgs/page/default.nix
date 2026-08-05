{
  lib,
  makeBinaryWrapper,
  neovim,
  page,
  stdenvNoCC,
  ...
}:
stdenvNoCC.mkDerivation {
  pname = "page-with-neovim";
  inherit (page) version;

  dontUnpack = true;

  nativeBuildInputs = [ makeBinaryWrapper ];

  installPhase = ''
    install -Dm755 ${lib.getExe page} $out/bin/page
    wrapProgram $out/bin/page --prefix PATH : ${lib.makeBinPath [ neovim ]}
  '';

  meta = page.meta // {
    description = "The page pager with Home Manager's Neovim on PATH";
    mainProgram = "page";
  };
}
