{
  lib,
  python3,
}:
python3.pkgs.buildPythonApplication {
  pname = "ollama-metrics";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ python3.pkgs.setuptools ];

  dependencies = with python3.pkgs; [
    prometheus-client
    pydantic
  ];

  nativeCheckInputs = with python3.pkgs; [
    mypy
    pytestCheckHook
    pytest-cov
    ruff
  ];

  preCheck = ''
    ruff format --check src tests
    ruff check src tests
    mypy src/ollama_metrics
  '';

  pythonImportsCheck = [ "ollama_metrics" ];

  meta = {
    description = "Prometheus textfile collector for Ollama state";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "ollama-metrics";
    platforms = lib.platforms.linux;
  };
}
