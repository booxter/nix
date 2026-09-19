{
  check-jsonschema,
  lib,
  stdenvNoCC,
}:
stdenvNoCC.mkDerivation {
  pname = "radarr-repair-contracts";
  version = "2";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./contracts/v1
      ./contracts/v2
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

    worker_schema_base="file://$PWD/worker/contracts/v1"

    check-jsonschema --check-metaschema contracts/v1/repair-case.schema.json
    check-jsonschema --check-metaschema contracts/v1/repair-decision.schema.json
    check-jsonschema --check-metaschema contracts/v2/repair-case.schema.json
    check-jsonschema --check-metaschema contracts/v2/repair-decision.schema.json
    check-jsonschema --check-metaschema worker/contracts/v1/join-request.schema.json
    check-jsonschema --check-metaschema worker/contracts/v1/join-response.schema.json
    check-jsonschema --check-metaschema worker/contracts/v1/bluray-identify-request.schema.json
    check-jsonschema --check-metaschema worker/contracts/v1/bluray-identify-response.schema.json
    check-jsonschema --check-metaschema worker/contracts/v1/media-evidence.schema.json
    check-jsonschema --check-metaschema worker/contracts/v1/probe-request.schema.json
    check-jsonschema --check-metaschema worker/contracts/v1/probe-response.schema.json
    check-jsonschema --check-metaschema worker/contracts/v1/wire-types.schema.json

    check-jsonschema \
      --schemafile contracts/v1/repair-case.schema.json \
      contracts/v1/examples/repair-case-*.json
    check-jsonschema \
      --schemafile contracts/v1/repair-decision.schema.json \
      contracts/v1/examples/repair-decision-*.json
    check-jsonschema \
      --schemafile contracts/v2/repair-case.schema.json \
      contracts/v2/examples/repair-case-*.json
    check-jsonschema \
      --schemafile contracts/v2/repair-decision.schema.json \
      contracts/v2/examples/repair-decision-*.json
    check-jsonschema \
      --base-uri "$worker_schema_base/probe-request.schema.json" \
      --schemafile worker/contracts/v1/probe-request.schema.json \
      worker/contracts/v1/examples/probe-request.json
    check-jsonschema \
      --base-uri "$worker_schema_base/bluray-identify-request.schema.json" \
      --schemafile worker/contracts/v1/bluray-identify-request.schema.json \
      worker/contracts/v1/examples/bluray-identify-request.json
    check-jsonschema \
      --base-uri "$worker_schema_base/bluray-identify-response.schema.json" \
      --schemafile worker/contracts/v1/bluray-identify-response.schema.json \
      worker/contracts/v1/examples/bluray-identify-response-ok.json \
      worker/contracts/v1/examples/bluray-identify-response-failed.json
    check-jsonschema \
      --base-uri "$worker_schema_base/probe-response.schema.json" \
      --schemafile worker/contracts/v1/probe-response.schema.json \
      worker/contracts/v1/examples/probe-response-ok.json \
      worker/contracts/v1/examples/probe-response-failed.json
    check-jsonschema \
      --base-uri "$worker_schema_base/join-request.schema.json" \
      --schemafile worker/contracts/v1/join-request.schema.json \
      worker/contracts/v1/examples/join-stage-request.json \
      worker/contracts/v1/examples/join-publish-request.json \
      worker/contracts/v1/examples/join-discard-request.json \
      worker/contracts/v1/examples/join-inspect-request.json
    check-jsonschema \
      --base-uri "$worker_schema_base/join-response.schema.json" \
      --schemafile worker/contracts/v1/join-response.schema.json \
      worker/contracts/v1/examples/join-stage-response-ok.json \
      worker/contracts/v1/examples/join-stage-response-failed.json \
      worker/contracts/v1/examples/join-publish-response-ok.json \
      worker/contracts/v1/examples/join-publish-response-failed.json \
      worker/contracts/v1/examples/join-discard-response-ok.json \
      worker/contracts/v1/examples/join-discard-response-failed.json \
      worker/contracts/v1/examples/join-inspect-response-ok.json \
      worker/contracts/v1/examples/join-inspect-response-failed.json

    expect_invalid() {
      schema="$1"
      fixture="$2"
      if check-jsonschema \
        --quiet \
        --base-uri "file://$PWD/$schema" \
        --schemafile "$schema" \
        "$fixture"; then
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
    for fixture in contract-tests/v2/decision-*.json; do
      expect_invalid contracts/v2/repair-decision.schema.json "$fixture"
    done
    for fixture in contract-tests/v2/request-*.json; do
      expect_invalid contracts/v2/repair-case.schema.json "$fixture"
    done
    for fixture in worker/contract-tests/v1/request-*.json; do
      expect_invalid worker/contracts/v1/probe-request.schema.json "$fixture"
    done
    for fixture in worker/contract-tests/v1/response-*.json; do
      expect_invalid worker/contracts/v1/probe-response.schema.json "$fixture"
    done
    for fixture in worker/contract-tests/v1/join-request-*.json; do
      expect_invalid worker/contracts/v1/join-request.schema.json "$fixture"
    done
    for fixture in worker/contract-tests/v1/join-response-*.json; do
      expect_invalid worker/contracts/v1/join-response.schema.json "$fixture"
    done

    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/share/radarr-repair/contracts"
    cp -R contracts/v1 "$out/share/radarr-repair/contracts/"
    cp -R contracts/v2 "$out/share/radarr-repair/contracts/"
    mkdir -p "$out/share/radarr-repair/contract-tests"
    cp -R contract-tests/v1 "$out/share/radarr-repair/contract-tests/"
    cp -R contract-tests/v2 "$out/share/radarr-repair/contract-tests/"
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
