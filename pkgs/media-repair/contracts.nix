{
  check-jsonschema,
  lib,
  stdenvNoCC,
}:
stdenvNoCC.mkDerivation {
  pname = "media-repair-contracts";
  version = "3";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./contracts/v3
      ./lidarrcontracts/v3
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

    check-jsonschema --check-metaschema contracts/v3/repair-case.schema.json
    check-jsonschema --check-metaschema contracts/v3/repair-decision.schema.json
    check-jsonschema --check-metaschema lidarrcontracts/v3/repair-case.schema.json
    check-jsonschema --check-metaschema lidarrcontracts/v3/repair-decision.schema.json
    check-jsonschema --check-metaschema worker/contracts/v1/bluray-identify-request.schema.json
    check-jsonschema --check-metaschema worker/contracts/v1/bluray-identify-response.schema.json
    check-jsonschema --check-metaschema worker/contracts/v1/dvd-identify-request.schema.json
    check-jsonschema --check-metaschema worker/contracts/v1/dvd-identify-response.schema.json
    check-jsonschema --check-metaschema worker/contracts/v1/media-evidence.schema.json
    check-jsonschema --check-metaschema worker/contracts/v1/probe-request.schema.json
    check-jsonschema --check-metaschema worker/contracts/v1/probe-response.schema.json
    check-jsonschema --check-metaschema worker/contracts/v1/wire-types.schema.json

    check-jsonschema \
      --schemafile contracts/v3/repair-case.schema.json \
      contracts/v3/examples/repair-case-*.json
    check-jsonschema \
      --schemafile contracts/v3/repair-decision.schema.json \
      contracts/v3/examples/repair-decision-*.json
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

    for fixture in contract-tests/v3/decision-*.json; do
      expect_invalid contracts/v3/repair-decision.schema.json "$fixture"
    done
    for fixture in contract-tests/v3/request-*.json; do
      expect_invalid contracts/v3/repair-case.schema.json "$fixture"
    done
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
    cp -R contracts/v3 "$out/share/radarr-repair/contracts/"
    mkdir -p "$out/share/lidarr-repair/contracts"
    cp -R lidarrcontracts/v3 "$out/share/lidarr-repair/contracts/"
    mkdir -p "$out/share/radarr-repair/contract-tests"
    cp -R contract-tests/v3 "$out/share/radarr-repair/contract-tests/"
    mkdir -p "$out/share/media-repair/worker-contracts"
    cp -R worker/contracts/v1 "$out/share/media-repair/worker-contracts/"

    runHook postInstall
  '';

  meta = {
    description = "Wire contracts for media repair services";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
}
