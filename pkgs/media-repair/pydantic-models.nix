{
  contracts,
  lib,
  python3Packages,
  ruff,
  runCommand,
}:
let
  radarrSchemaDirectory = "${contracts}/share/radarr-repair/contracts/v3";
  lidarrSchemaDirectory = "${contracts}/share/lidarr-repair/contracts/v3";
  generate = schemaDirectory: schema: className: output: ''
    datamodel-codegen \
      --input "${schemaDirectory}/${schema}" \
      --input-file-type jsonschema \
      --output "$out/${output}" \
      --output-model-type pydantic_v2.BaseModel \
      --class-name ${className} \
      --target-python-version 3.13 \
      --field-constraints \
      --use-annotated \
      --use-union-operator \
      --strict-types str bytes int float bool \
      --extra-fields forbid \
      --disable-timestamp
  '';
in
runCommand "media-repair-pydantic-models-v3"
  {
    nativeBuildInputs = [
      python3Packages.datamodel-code-generator
      ruff
    ];

    meta = {
      description = "Generated Pydantic models for media repair contracts";
      license = lib.licenses.mit;
      platforms = lib.platforms.linux;
    };
  }
  ''
    mkdir "$out"
    ${generate radarrSchemaDirectory "repair-case.schema.json" "RepairCaseV3" "case_models.py"}
    ${generate radarrSchemaDirectory "repair-decision.schema.json" "RepairDecisionV3"
      "decision_models.py"
    }
    ${generate lidarrSchemaDirectory "repair-case.schema.json" "LidarrRepairCaseV3"
      "lidarr_case_models.py"
    }
    ${generate lidarrSchemaDirectory "repair-decision.schema.json" "LidarrRepairDecisionV3"
      "lidarr_decision_models.py"
    }
    ruff format --config ${../../ruff.toml} "$out"
  ''
