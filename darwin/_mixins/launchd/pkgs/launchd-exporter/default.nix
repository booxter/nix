{
  lib,
  swift,
  swiftPackages,
  swiftpm,
}:
swiftPackages.stdenv.mkDerivation {
  pname = "darwin-launchd-exporter";
  version = "1";

  src = ./.;

  nativeBuildInputs = [
    swift
    swiftpm
  ];

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    "$(swiftpmBinPath)/LaunchdExporterChecks"
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    install -D -m 0755 \
      "$(swiftpmBinPath)/observability-launchd-export" \
      "$out/bin/observability-launchd-export"
    runHook postInstall
  '';

  meta = {
    description = "Export native launchd job state as Prometheus metrics";
    license = lib.licenses.mit;
    mainProgram = "observability-launchd-export";
    platforms = lib.platforms.darwin;
  };
}
