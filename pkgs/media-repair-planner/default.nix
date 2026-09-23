{
  contracts,
  jq,
  lib,
  pydanticModels,
  python3Packages,
  pythonRuffCheckHook,
}:
python3Packages.buildPythonApplication {
  pname = "media-repair-planner";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  postPatch = ''
    cp ${pydanticModels}/case_models.py \
      src/media_repair_planner/case_models.py
    cp ${pydanticModels}/decision_models.py \
      src/media_repair_planner/decision_models.py
    cp ${pydanticModels}/lidarr_case_models.py \
      src/media_repair_planner/lidarr_case_models.py
    cp ${pydanticModels}/lidarr_decision_models.py \
      src/media_repair_planner/lidarr_decision_models.py
    mkdir -p src/media_repair_planner/schemas
    cp ${contracts}/share/radarr-repair/contracts/v3/*.schema.json \
      src/media_repair_planner/schemas/
    cp ${contracts}/share/lidarr-repair/contracts/v2/repair-case.schema.json \
      src/media_repair_planner/schemas/lidarr-repair-case.schema.json
    cp ${contracts}/share/lidarr-repair/contracts/v2/repair-decision.schema.json \
      src/media_repair_planner/schemas/lidarr-repair-decision.schema.json
    mkdir -p src/media_repair_planner/evaluations/v3/cases
    cp ${contracts}/share/radarr-repair/contracts/v3/examples/repair-case-*.json \
      src/media_repair_planner/evaluations/v3/cases/
    cp corpus-review/*/*.json \
      src/media_repair_planner/evaluations/v3/cases/
    for case in src/media_repair_planner/evaluations/v3/cases/*.json; do
      jq \
        '.schema_version = "radarr-repair/v3"
        | .radarr.failure.status_message_count = (.radarr.failure.status_messages | length)
        | .radarr.failure.status_messages |= map(.message_count = (.messages | length))' \
        "$case" > "$case.migrated"
      mv "$case.migrated" "$case"
    done
  '';

  build-system = [ python3Packages.setuptools ];

  dependencies = with python3Packages; [
    fastapi
    jsonschema
    ollama
    openai
    pydantic
    uvicorn
  ];

  nativeBuildInputs = [ jq ];

  nativeCheckInputs = with python3Packages; [
    httpx
    mypy
    pytest-asyncio
    pytestCheckHook
    pytest-cov
    pythonRuffCheckHook
    trustme
  ];

  RADARR_REPAIR_CONTRACT_FIXTURES = "${contracts}/share/radarr-repair";

  preCheck = ''
    mypy src/media_repair_planner
  '';
  postCheck = ''
    "$out/bin/media-repair-planner" validate-case \
      ${contracts}/share/radarr-repair/contracts/v3/examples/repair-case-joinable.json
    "$out/bin/media-repair-planner" validate-decision \
      ${contracts}/share/radarr-repair/contracts/v3/examples/repair-decision-join.json
    "$out/bin/media-repair-planner-evaluate-radarr" --help >/dev/null
    "$out/bin/media-repair-planner-evaluate-lidarr" --help >/dev/null
    "$out/bin/media-repair-planner-serve" --help >/dev/null
  '';

  pythonImportsCheck = [ "media_repair_planner" ];

  meta = {
    description = "Agentic planner for media import repair";
    license = lib.licenses.mit;
    mainProgram = "media-repair-planner";
    platforms = lib.platforms.linux;
  };
}
