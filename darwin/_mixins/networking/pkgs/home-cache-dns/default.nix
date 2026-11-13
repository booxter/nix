{
  lib,
  swift,
  swiftPackages,
  swiftpm,
}:
swiftPackages.stdenv.mkDerivation {
  pname = "home-cache-dns";
  version = "1";

  src = ./.;
  nativeBuildInputs = [
    swift
    swiftpm
  ];

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    "$(swiftpmBinPath)/HomeCacheDNSChecks"
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    install -D -m 0755 "$(swiftpmBinPath)/home-cache-dns" "$out/bin/home-cache-dns"
    runHook postInstall
  '';

  meta = {
    description = "Prefer LAN DNS for the home cache when its identity is reachable locally";
    license = lib.licenses.mit;
    mainProgram = "home-cache-dns";
    platforms = lib.platforms.darwin;
  };
}
