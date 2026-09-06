{
  check-jsonschema,
  lib,
  stdenvNoCC,
}:
stdenvNoCC.mkDerivation {
  pname = "radarr-repair-contracts";
  version = "1";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./contracts/v1
      ./contract-tests
    ];
  };

  dontConfigure = true;
  dontBuild = true;

  nativeCheckInputs = [ check-jsonschema ];
  doCheck = true;

  checkPhase = ''
    runHook preCheck

    check-jsonschema --check-metaschema contracts/v1/repair-case.schema.json
    check-jsonschema --check-metaschema contracts/v1/repair-decision.schema.json

    check-jsonschema \
      --schemafile contracts/v1/repair-case.schema.json \
      contracts/v1/examples/repair-case-joinable.json
    check-jsonschema \
      --schemafile contracts/v1/repair-decision.schema.json \
      contracts/v1/examples/repair-decision-join.json \
      contracts/v1/examples/repair-decision-no-repair.json

    expect_invalid() {
      schema="$1"
      fixture="$2"
      if check-jsonschema --quiet --schemafile "$schema" "$fixture"; then
        echo "expected contract fixture to be rejected: $fixture" >&2
        exit 1
      fi
    }

    for fixture in contract-tests/v1/decision-*.json; do
      expect_invalid contracts/v1/repair-decision.schema.json "$fixture"
    done
    expect_invalid \
      contracts/v1/repair-case.schema.json \
      contract-tests/v1/request-unknown-field.json

    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/share/radarr-repair/contracts"
    cp -R contracts/v1 "$out/share/radarr-repair/contracts/"

    runHook postInstall
  '';

  meta = {
    description = "Versioned wire contracts for Radarr repair planning";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
}
