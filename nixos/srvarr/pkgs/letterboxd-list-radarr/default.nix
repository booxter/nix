{
  buildNpmPackage,
  fetchFromGitHub,
  lib,
  makeWrapper,
  nodejs_24,
}:

buildNpmPackage rec {
  pname = "letterboxd-list-radarr";
  version = "1.2.2-unstable-2026-06-16";

  src = fetchFromGitHub {
    owner = "screeny05";
    repo = "letterboxd-list-radarr";
    rev = "25c4981346083a8a58fdc694160cb7c9cd678c05";
    hash = "sha256-dLsP4vhKUekZnTAqQnNIEbO5TrBowi6tojVgaFsvnxY=";
  };

  nodejs = nodejs_24;
  npmDepsHash = "sha256-Ybdu4pbppy85BpDOuv2WtPMHF16qlE8R09fXby6NwqU=";

  nativeBuildInputs = [
    makeWrapper
  ];

  installPhase = ''
    runHook preInstall

    npm prune --omit=dev --ignore-scripts

    mkdir -p "$out/bin" "$out/lib/${pname}"
    cp package.json "$out/lib/${pname}/"
    cp -r dist node_modules "$out/lib/${pname}/"

    makeWrapper ${lib.getExe nodejs_24} "$out/bin/${pname}" \
      --add-flags "$out/lib/${pname}/dist/index.js"

    runHook postInstall
  '';

  meta = {
    description = "Convert Letterboxd lists to Radarr-compatible JSON import lists";
    homepage = "https://github.com/screeny05/letterboxd-list-radarr";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = pname;
    platforms = lib.platforms.linux;
  };
}
