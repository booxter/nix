{
  lib,
  makeWrapper,
  namedPublicKeys ? [ ],
  indicator ? { },
  swift,
  swiftPackages,
  swiftpm,
}:

swiftPackages.stdenv.mkDerivation {
  pname = "ssh-askpass-macos";
  version = "1";

  src = ./.;

  nativeBuildInputs = [
    makeWrapper
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
    wrapProgram "$out/bin/ssh-askpass-macos" \
      --set SSH_ASKPASS_NAMED_KEYS ${lib.escapeShellArg (builtins.toJSON namedPublicKeys)} \
      ${lib.optionalString (indicator != { }) ''
        --set SSH_ASKPASS_INDICATOR ${lib.escapeShellArg (builtins.toJSON indicator)}
      ''}
    runHook postInstall
  '';

  meta = {
    description = "Native macOS OpenSSH askpass dialog";
    license = lib.licenses.mit;
    mainProgram = "ssh-askpass-macos";
    platforms = lib.platforms.darwin;
  };
}
