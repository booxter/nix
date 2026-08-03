{
  lib,
  swift,
  swiftPackages,
  swiftpm,
}:

swiftPackages.stdenv.mkDerivation (finalAttrs: {
  pname = "sketchybar-swift-applets";
  version = "1";

  src = ./.;

  nativeBuildInputs = [
    swift
    swiftpm
  ];

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    "$(swiftpmBinPath)/BatteryAppletChecks"
    "$(swiftpmBinPath)/SpotifyAppletChecks"
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin"
    for executable in sketchybar-battery sketchybar-spotify; do
      install -m 0755 "$(swiftpmBinPath)/$executable" "$out/bin/$executable"
    done
    runHook postInstall
  '';

  meta = {
    description = "Native Swift applets for SketchyBar";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "sketchybar-spotify";
    platforms = lib.platforms.darwin;
  };
})
