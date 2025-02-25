{ lib, pkgs, ... }: pkgs.stdenv.mkDerivation {
  pname = "homerow";
  version = "1.22";

  src = pkgs.fetchzip {
    # TODO: find a stable url that doesn't get overridden on updates
    url = "https://builds.homerow.app/latest/Homerow.zip";
    extension = "zip";
    hash = "sha256-AfV7IyrCDELPpwDBl6SmPhwXIkXwcu5PAdwcYM2eMOE=";
  };

  nativeBuildInputs = with pkgs; [ unzip ];
  phases = ["unpackPhase" "installPhase"];
  sourceRoot = ".";

  installPhase = ''
    runHook preInstall
    mkdir -p $out/Applications
    cp -r source $out/Applications/Homerow.app
    runHook postInstall
  '';

  meta = with lib; {
    description = "Homerow";
    homepage = "https://www.homerow.app/";
    maintainers = [ lib.maintainers.booxter ];
    platforms = platforms.darwin;
  };
}
