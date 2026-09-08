{
  contracts,
  lib,
  python3Packages,
  ruff,
  runCommand,
}:
let
  schemaDirectory = "${contracts}/share/radarr-repair/contracts/v1";
  generate = schema: className: output: ''
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
runCommand "radarr-repair-pydantic-models-v1"
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
    ${generate "repair-case.schema.json" "RepairCaseV1" "case_models.py"}
    ${generate "repair-decision.schema.json" "RepairDecisionV1" "decision_models.py"}
    ruff format --config ${../../ruff.toml} "$out"
  ''
