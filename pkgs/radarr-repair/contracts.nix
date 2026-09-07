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
      ./worker/contracts/v1
      ./worker/contract-tests
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
    check-jsonschema --check-metaschema worker/contracts/v1/probe-request.schema.json
    check-jsonschema --check-metaschema worker/contracts/v1/probe-response.schema.json

    check-jsonschema \
      --schemafile contracts/v1/repair-case.schema.json \
      contracts/v1/examples/repair-case-joinable.json
    check-jsonschema \
      --schemafile contracts/v1/repair-decision.schema.json \
      contracts/v1/examples/repair-decision-join.json \
      contracts/v1/examples/repair-decision-no-repair.json
    check-jsonschema \
      --schemafile worker/contracts/v1/probe-request.schema.json \
      worker/contracts/v1/examples/probe-request.json
    check-jsonschema \
      --schemafile worker/contracts/v1/probe-response.schema.json \
      worker/contracts/v1/examples/probe-response-ok.json \
      worker/contracts/v1/examples/probe-response-failed.json

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
    for fixture in worker/contract-tests/v1/request-*.json; do
      expect_invalid worker/contracts/v1/probe-request.schema.json "$fixture"
    done
    for fixture in worker/contract-tests/v1/response-*.json; do
      expect_invalid worker/contracts/v1/probe-response.schema.json "$fixture"
    done

    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/share/radarr-repair/contracts"
    cp -R contracts/v1 "$out/share/radarr-repair/contracts/"
    mkdir -p "$out/share/radarr-repair/worker-contracts"
    cp -R worker/contracts/v1 "$out/share/radarr-repair/worker-contracts/"

    runHook postInstall
  '';

  meta = {
    description = "Versioned wire contracts for Radarr repair services";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
}
