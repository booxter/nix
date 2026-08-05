{
  lib,
  swift,
  swiftPackages,
  swiftpm,
}:
swiftPackages.stdenv.mkDerivation {
  pname = "darwin-thermal-exporter";
  version = "1";

  src = ./.;

  nativeBuildInputs = [
    swift
    swiftpm
  ];

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    "$(swiftpmBinPath)/ThermalExporterChecks"
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    install -D -m 0755 \
      "$(swiftpmBinPath)/observability-thermal-export" \
      "$out/bin/observability-thermal-export"
    runHook postInstall
  '';

  meta = {
    description = "Native Darwin thermal and power metrics exporter";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "observability-thermal-export";
    platforms = lib.platforms.darwin;
  };
}
