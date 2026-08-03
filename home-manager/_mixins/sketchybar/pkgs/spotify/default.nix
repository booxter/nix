{
  lib,
  swift,
  swiftPackages,
  swiftpm,
}:

swiftPackages.stdenv.mkDerivation (finalAttrs: {
  pname = "sketchybar-spotify";
  version = "1";

  src = ./.;

  nativeBuildInputs = [
    swift
    swiftpm
  ];

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    "$(swiftpmBinPath)/SpotifyAppletChecks"
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin"
    install -m 0755 \
      "$(swiftpmBinPath)/${finalAttrs.meta.mainProgram}" \
      "$out/bin/${finalAttrs.meta.mainProgram}"
    runHook postInstall
  '';

  meta = {
    description = "Native Spotify controller for SketchyBar";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "sketchybar-spotify";
    platforms = lib.platforms.darwin;
  };
})
