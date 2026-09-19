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
      };
      required = [
        "join_decision"
        "manual_import_file_decision"
        "no_repair_decision"
        "remux_bluray_decision"
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
        bluray_identify_request_v1 = {
          "$ref" = "bluray-identify-request.schema.json";
        };
        bluray_identify_failure_response_v1 = {
          "$ref" = "bluray-identify-response.schema.json#/$defs/failure";
        };
        bluray_identify_success_response_v1 = {
          "$ref" = "bluray-identify-response.schema.json#/$defs/success";
        };
        bluray_remux_request_v1 = {
          "$ref" = "bluray-remux-request.schema.json";
        };
        bluray_remux_failure_response_v1 = {
          "$ref" = "bluray-remux-response.schema.json#/$defs/failure";
        };
        bluray_remux_success_response_v1 = {
          "$ref" = "bluray-remux-response.schema.json#/$defs/success";
        };
        bluray_publish_request_v1 = {
          "$ref" = "bluray-publish-request.schema.json";
        };
        bluray_publish_failure_response_v1 = {
          "$ref" = "bluray-publish-response.schema.json#/$defs/failure";
        };
        bluray_publish_success_response_v1 = {
          "$ref" = "bluray-publish-response.schema.json#/$defs/success";
        };
        discard_request_v1 = {
          "$ref" = "join-request.schema.json#/$defs/discard";
        };
        discard_failure_response_v1 = {
          "$ref" = "join-response.schema.json#/$defs/discardFailure";
        };
        discard_success_response_v1 = {
          "$ref" = "join-response.schema.json#/$defs/discardSuccess";
        };
        inspect_join_request_v1 = {
          "$ref" = "join-request.schema.json#/$defs/inspectJoin";
        };
        inspect_join_failure_response_v1 = {
          "$ref" = "join-response.schema.json#/$defs/inspectJoinFailure";
        };
        inspect_join_success_response_v1 = {
          "$ref" = "join-response.schema.json#/$defs/inspectJoinSuccess";
        };
        publish_request_v1 = {
          "$ref" = "join-request.schema.json#/$defs/publish";
        };
        publish_failure_response_v1 = {
          "$ref" = "join-response.schema.json#/$defs/publishFailure";
        };
        publish_success_response_v1 = {
          "$ref" = "join-response.schema.json#/$defs/publishSuccess";
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
        stage_join_request_v1 = {
          "$ref" = "join-request.schema.json#/$defs/stageJoin";
        };
        stage_join_failure_response_v1 = {
          "$ref" = "join-response.schema.json#/$defs/stageJoinFailure";
        };
        stage_join_success_response_v1 = {
          "$ref" = "join-response.schema.json#/$defs/stageJoinSuccess";
        };
      };
      required = [
        "bluray_identify_request_v1"
        "bluray_identify_failure_response_v1"
        "bluray_identify_success_response_v1"
        "bluray_remux_request_v1"
        "bluray_remux_failure_response_v1"
        "bluray_remux_success_response_v1"
        "bluray_publish_request_v1"
        "bluray_publish_failure_response_v1"
        "bluray_publish_success_response_v1"
        "discard_request_v1"
        "discard_failure_response_v1"
        "discard_success_response_v1"
        "inspect_join_request_v1"
        "inspect_join_failure_response_v1"
        "inspect_join_success_response_v1"
        "publish_request_v1"
        "publish_failure_response_v1"
        "publish_success_response_v1"
        "probe_request_v1"
        "probe_success_response_v1"
        "probe_failure_response_v1"
        "stage_join_request_v1"
        "stage_join_failure_response_v1"
        "stage_join_success_response_v1"
      ];
    }
  );
  schemaDirectory = "${contracts}/share/radarr-repair/contracts/v2";
  workerSchemaDirectory = "${contracts}/share/radarr-repair/worker-contracts/v1";
in
runCommand "radarr-repair-go-models-v2"
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
    ln -s "${workerSchemaDirectory}/join-request.schema.json" work/join-request.schema.json
    ln -s "${workerSchemaDirectory}/bluray-identify-request.schema.json" work/bluray-identify-request.schema.json
    ln -s "${workerSchemaDirectory}/bluray-identify-response.schema.json" work/bluray-identify-response.schema.json
    ln -s "${workerSchemaDirectory}/bluray-remux-request.schema.json" work/bluray-remux-request.schema.json
    ln -s "${workerSchemaDirectory}/bluray-remux-response.schema.json" work/bluray-remux-response.schema.json
    ln -s "${workerSchemaDirectory}/bluray-publish-request.schema.json" work/bluray-publish-request.schema.json
    ln -s "${workerSchemaDirectory}/bluray-publish-response.schema.json" work/bluray-publish-response.schema.json
    ln -s "${workerSchemaDirectory}/join-response.schema.json" work/join-response.schema.json
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
