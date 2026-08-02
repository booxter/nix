{
  lib,
  python3,
  stdenvNoCC,
}:
let
  patchSource = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.fileFilter (
      file: lib.hasSuffix ".patch" file.name || lib.hasSuffix ".diff" file.name
    ) ../..;
  };
in
stdenvNoCC.mkDerivation {
  pname = "patch-context";
  version = "1";
  src = ./.;

  doCheck = true;
  nativeCheckInputs = [ python3 ];
  checkPhase = ''
    runHook preCheck
    python3 -m unittest discover -s . -p 'test_patch_context.py'
    python3 check_patch_context.py ${patchSource}
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 check_patch_context.py "$out/bin/check-patch-context"
    runHook postInstall
  '';

  meta = {
    description = "Reject patch edit hunks without unchanged context";
    mainProgram = "check-patch-context";
  };
}
