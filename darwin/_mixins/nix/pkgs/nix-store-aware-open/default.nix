{
  bats,
  coreutils,
  lib,
  runCommand,
  stdenvNoCC,
}:
let
  testApp = runCommand "nix-store-aware-open-test-app" { } ''
    mkdir -p "$out/Applications/Test App.app/Contents"
    echo fixture > "$out/Applications/Test App.app/Contents/fixture"
  '';
in
stdenvNoCC.mkDerivation {
  pname = "nix-store-aware-open";
  version = "1";

  dontUnpack = true;
  strictDeps = true;

  nativeCheckInputs = [ bats ];
  doCheck = true;

  checkPhase = ''
    runHook preCheck

    substitute ${./open.sh} open-under-test \
      --replace-fail @open@ "$PWD/fake-open" \
      --replace-fail @chmod@ ${lib.getExe' coreutils "chmod"} \
      --replace-fail @cp@ ${lib.getExe' coreutils "cp"} \
      --replace-fail @mkdir@ ${lib.getExe' coreutils "mkdir"} \
      --replace-fail @mv@ ${lib.getExe' coreutils "mv"} \
      --replace-fail @realpath@ ${lib.getExe' coreutils "realpath"} \
      --replace-fail @rm@ ${lib.getExe' coreutils "rm"}
    chmod +x open-under-test

    cat > fake-open <<'EOF'
    #!/bin/bash
    printf '%s\n' "$@" > "$OPEN_CAPTURE"
    EOF
    chmod +x fake-open

    export OPEN_UNDER_TEST="$PWD/open-under-test"
    export TEST_STORE_APP=${lib.escapeShellArg "${testApp}/Applications/Test App.app"}
    bats ${./open.bats}

    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/bin"
    substitute ${./open.sh} "$out/bin/open" \
      --replace-fail @open@ /usr/bin/open \
      --replace-fail @chmod@ ${lib.getExe' coreutils "chmod"} \
      --replace-fail @cp@ ${lib.getExe' coreutils "cp"} \
      --replace-fail @mkdir@ ${lib.getExe' coreutils "mkdir"} \
      --replace-fail @mv@ ${lib.getExe' coreutils "mv"} \
      --replace-fail @realpath@ ${lib.getExe' coreutils "realpath"} \
      --replace-fail @rm@ ${lib.getExe' coreutils "rm"}
    chmod +x "$out/bin/open"

    runHook postInstall
  '';

  meta = {
    description = "Open copies of macOS app bundles instead of Nix store paths";
    license = lib.licenses.mit;
    mainProgram = "open";
    platforms = lib.platforms.darwin;
  };
}
