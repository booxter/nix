{
  contracts,
  lib,
  python3Packages,
  ruff,
  runCommand,
}:
let
  radarrSchemaDirectory = "${contracts}/share/radarr-repair/contracts/v2";
  lidarrSchemaDirectory = "${contracts}/share/lidarr-repair/contracts/v2";
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
runCommand "radarr-repair-pydantic-models-v2"
  {
    nativeBuildInputs = [
      python3Packages.datamodel-code-generator
      ruff
    ];

    meta = {
      description = "Generated Pydantic models for Radarr repair contracts";
      license = lib.licenses.mit;
      platforms = lib.platforms.linux;
    };
  }
  ''
    mkdir "$out"
    ${generate radarrSchemaDirectory "repair-case.schema.json" "RepairCaseV2" "case_models.py"}
    ${generate radarrSchemaDirectory "repair-decision.schema.json" "RepairDecisionV2"
      "decision_models.py"
    }
    ${generate lidarrSchemaDirectory "repair-case.schema.json" "LidarrRepairCaseV2"
      "lidarr_case_models.py"
    }
    ${generate lidarrSchemaDirectory "repair-decision.schema.json" "LidarrRepairDecisionV2"
      "lidarr_decision_models.py"
    }
    ruff format --config ${../../ruff.toml} "$out"
  ''
