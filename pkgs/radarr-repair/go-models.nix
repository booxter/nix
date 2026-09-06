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
        no_repair_decision = {
          "$ref" = "repair-decision.schema.json#/$defs/noRepair";
        };
      };
      required = [
        "join_decision"
        "no_repair_decision"
      ];
    }
  );
  schemaDirectory = "${contracts}/share/radarr-repair/contracts/v1";
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

    quicktype \
      --telemetry disable \
      --src-lang schema \
      --lang go \
      --package contracts \
      --just-types-and-package \
      --out "$out/models.gen.go" \
      "${schemaDirectory}/repair-case.schema.json" \
      work/decision-variants.schema.json
    gofmt -w "$out/models.gen.go"
  ''
