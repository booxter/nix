{
  contracts,
  go,
  lib,
  quicktype,
  runCommand,
  writeText,
}:
let
  decisionVariants = writeText "radarr-repair-decision-variants.schema.json" (
    builtins.toJSON {
      "$schema" = "https://json-schema.org/draft/2020-12/schema";
      title = "Decision variants";
      type = "object";
      additionalProperties = false;
      properties = {
        join_decision = {
          "$ref" = "repair-decision.schema.json#/$defs/joinParts";
        };
        manual_import_file_decision = {
          "$ref" = "repair-decision.schema.json#/$defs/manualImportFile";
        };
        no_repair_decision = {
          "$ref" = "repair-decision.schema.json#/$defs/noRepair";
        };
      };
      required = [
        "join_decision"
        "manual_import_file_decision"
        "no_repair_decision"
      ];
    }
  );
  workerWireModels = writeText "radarr-repair-worker-wire-models.schema.json" (
    builtins.toJSON {
      "$schema" = "https://json-schema.org/draft/2020-12/schema";
      title = "Worker wire models";
      type = "object";
      additionalProperties = false;
      properties = {
        probe_request_v1 = {
          "$ref" = "probe-request.schema.json";
        };
        probe_success_response_v1 = {
          "$ref" = "probe-response.schema.json#/$defs/success";
        };
        probe_failure_response_v1 = {
          "$ref" = "probe-response.schema.json#/$defs/failure";
        };
      };
      required = [
        "probe_request_v1"
        "probe_success_response_v1"
        "probe_failure_response_v1"
      ];
    }
  );
  schemaDirectory = "${contracts}/share/radarr-repair/contracts/v1";
  workerSchemaDirectory = "${contracts}/share/radarr-repair/worker-contracts/v1";
in
runCommand "radarr-repair-go-models-v1"
  {
    nativeBuildInputs = [
      go
      quicktype
    ];

    meta = {
      description = "Generated Go models for the Radarr repair wire contracts";
      license = lib.licenses.mit;
      platforms = lib.platforms.unix;
    };
  }
  ''
    mkdir work "$out"
    ln -s "${schemaDirectory}/repair-decision.schema.json" work/repair-decision.schema.json
    cp "${decisionVariants}" work/decision-variants.schema.json
    ln -s "${workerSchemaDirectory}/media-evidence.schema.json" work/media-evidence.schema.json
    ln -s "${workerSchemaDirectory}/probe-request.schema.json" work/probe-request.schema.json
    ln -s "${workerSchemaDirectory}/probe-response.schema.json" work/probe-response.schema.json
    cp "${workerWireModels}" work/worker-wire-models.schema.json

    quicktype \
      --telemetry disable \
      --src-lang schema \
      --lang go \
      --package contracts \
      --just-types-and-package \
      --out "$out/models.gen.go" \
      "${schemaDirectory}/repair-case.schema.json" \
      work/decision-variants.schema.json
    quicktype \
      --telemetry disable \
      --src-lang schema \
      --lang go \
      --package workercontracts \
      --just-types-and-package \
      --out "$out/worker-models.gen.go" \
      work/worker-wire-models.schema.json
    gofmt -w "$out/models.gen.go" "$out/worker-models.gen.go"
  ''
