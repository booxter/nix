{
  contracts,
  lib,
  pydanticModels,
  python3Packages,
  pythonRuffCheckHook,
}:
python3Packages.buildPythonApplication {
  pname = "radarr-repair-planner";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  postPatch = ''
    cp ${pydanticModels}/case_models.py \
      src/radarr_repair_planner/case_models.py
    cp ${pydanticModels}/decision_models.py \
      src/radarr_repair_planner/decision_models.py
    cp ${pydanticModels}/lidarr_case_models.py \
      src/radarr_repair_planner/lidarr_case_models.py
    cp ${pydanticModels}/lidarr_decision_models.py \
      src/radarr_repair_planner/lidarr_decision_models.py
    mkdir -p src/radarr_repair_planner/schemas
    cp ${contracts}/share/radarr-repair/contracts/v2/*.schema.json \
      src/radarr_repair_planner/schemas/
    cp ${contracts}/share/lidarr-repair/contracts/v1/repair-case.schema.json \
      src/radarr_repair_planner/schemas/lidarr-repair-case.schema.json
    cp ${contracts}/share/lidarr-repair/contracts/v1/repair-decision.schema.json \
      src/radarr_repair_planner/schemas/lidarr-repair-decision.schema.json
    mkdir -p src/radarr_repair_planner/evaluations/v2/cases
    cp ${contracts}/share/radarr-repair/contracts/v2/examples/repair-case-*.json \
      src/radarr_repair_planner/evaluations/v2/cases/
    cp corpus-review/*/*.json \
      src/radarr_repair_planner/evaluations/v2/cases/
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
    mypy src/radarr_repair_planner
  '';
  postCheck = ''
    "$out/bin/radarr-repair-planner" validate-case \
      ${contracts}/share/radarr-repair/contracts/v2/examples/repair-case-joinable.json
    "$out/bin/radarr-repair-planner" validate-decision \
      ${contracts}/share/radarr-repair/contracts/v2/examples/repair-decision-join.json
    "$out/bin/radarr-repair-planner-evaluate" --help >/dev/null
    "$out/bin/radarr-repair-planner-serve" --help >/dev/null
  '';

  pythonImportsCheck = [ "radarr_repair_planner" ];

  meta = {
    description = "Agentic planner for media import repair";
    license = lib.licenses.mit;
    mainProgram = "radarr-repair-planner";
    platforms = lib.platforms.linux;
  };
}
