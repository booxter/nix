{
  lib,
  swift,
  swiftPackages,
  swiftpm,
}:

swiftPackages.stdenv.mkDerivation {
  pname = "ssh-askpass-macos";
  version = "1";

  src = ./.;

  nativeBuildInputs = [
    swift
    swiftpm
  ];

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    "$(swiftpmBinPath)/AskpassCoreChecks"
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin"
    install -m 0755 \
      "$(swiftpmBinPath)/ssh-askpass-macos" \
      "$out/bin/ssh-askpass-macos"
    runHook postInstall
  '';

  meta = {
    description = "Native macOS OpenSSH askpass dialog";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "ssh-askpass-macos";
    platforms = lib.platforms.darwin;
  };
}
