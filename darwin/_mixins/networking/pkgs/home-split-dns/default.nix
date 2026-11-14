{
  lib,
  swift,
  swiftPackages,
  swiftpm,
}:
swiftPackages.stdenv.mkDerivation {
  pname = "home-split-dns";
  version = "1";

  src = ./.;
  nativeBuildInputs = [
    swift
    swiftpm
  ];

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    "$(swiftpmBinPath)/HomeSplitDNSChecks"
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    install -D -m 0755 "$(swiftpmBinPath)/home-split-dns" "$out/bin/home-split-dns"
    runHook postInstall
  '';

  meta = {
    description = "Prefer LAN DNS for home services with locally reachable TLS identities";
    license = lib.licenses.mit;
    mainProgram = "home-split-dns";
    platforms = lib.platforms.darwin;
  };
}
