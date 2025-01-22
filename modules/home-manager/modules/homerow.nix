{ pkgs, lib, ... }: with pkgs; stdenv.mkDerivation {
  pname = "homerow";
  version = "1.22";

  src = fetchzip {
    url = "https://builds.homerow.app/latest/Homerow.zip";
    extension = "zip";
    hash = "sha256-CBW+ECLziGsa6lfTKxexaj9FjAfBNra53IftTxQQZmU=";
  };

  nativeBuildInputs = [ unzip ];
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
    maintainers = [ "Ihar Hrachyshka" ];
    platforms = platforms.darwin;
  };
}
