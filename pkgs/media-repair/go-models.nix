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
        remux_bluray_decision = {
          "$ref" = "repair-decision.schema.json#/$defs/remuxBluray";
        };
        remux_dvd_decision = {
          "$ref" = "repair-decision.schema.json#/$defs/remuxDVD";
        };
      };
      required = [
        "join_decision"
        "manual_import_file_decision"
        "no_repair_decision"
        "remux_bluray_decision"
        "remux_dvd_decision"
      ];
    }
  );
  workerWireModels = writeText "media-repair-worker-wire-models.schema.json" (
    builtins.toJSON {
      "$schema" = "https://json-schema.org/draft/2020-12/schema";
      title = "Worker wire models";
      type = "object";
      additionalProperties = false;
      properties = {
        dvd_identify_request_v1 = {
          "$ref" = "dvd-identify-request.schema.json";
        };
        dvd_identify_failure_response_v1 = {
          "$ref" = "dvd-identify-response.schema.json#/$defs/failure";
        };
        dvd_identify_success_response_v1 = {
          "$ref" = "dvd-identify-response.schema.json#/$defs/success";
        };
        bluray_identify_request_v1 = {
          "$ref" = "bluray-identify-request.schema.json";
        };
        bluray_identify_failure_response_v1 = {
          "$ref" = "bluray-identify-response.schema.json#/$defs/failure";
        };
        bluray_identify_success_response_v1 = {
          "$ref" = "bluray-identify-response.schema.json#/$defs/success";
        };
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
        "dvd_identify_request_v1"
        "dvd_identify_failure_response_v1"
        "dvd_identify_success_response_v1"
        "bluray_identify_request_v1"
        "bluray_identify_failure_response_v1"
        "bluray_identify_success_response_v1"
        "probe_request_v1"
        "probe_success_response_v1"
        "probe_failure_response_v1"
      ];
    }
  );
  schemaDirectory = "${contracts}/share/radarr-repair/contracts/v3";
  workerSchemaDirectory = "${contracts}/share/media-repair/worker-contracts/v1";
in
runCommand "media-repair-go-models-v3"
  {
    nativeBuildInputs = [
      go
      quicktype
    ];

    meta = {
      description = "Generated Go models for media repair wire contracts";
      license = lib.licenses.mit;
      platforms = lib.platforms.unix;
    };
  }
  ''
    mkdir work "$out"
    ln -s "${schemaDirectory}/repair-decision.schema.json" work/repair-decision.schema.json
    cp "${decisionVariants}" work/decision-variants.schema.json
    ln -s "${workerSchemaDirectory}/bluray-identify-request.schema.json" work/bluray-identify-request.schema.json
    ln -s "${workerSchemaDirectory}/bluray-identify-response.schema.json" work/bluray-identify-response.schema.json
    ln -s "${workerSchemaDirectory}/dvd-identify-request.schema.json" work/dvd-identify-request.schema.json
    ln -s "${workerSchemaDirectory}/dvd-identify-response.schema.json" work/dvd-identify-response.schema.json
    ln -s "${workerSchemaDirectory}/media-evidence.schema.json" work/media-evidence.schema.json
    ln -s "${workerSchemaDirectory}/probe-request.schema.json" work/probe-request.schema.json
    ln -s "${workerSchemaDirectory}/probe-response.schema.json" work/probe-response.schema.json
    ln -s "${workerSchemaDirectory}/wire-types.schema.json" work/wire-types.schema.json
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
