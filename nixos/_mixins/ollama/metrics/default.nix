{
  lib,
  python3,
  pythonRuffCheckHook,
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
    pythonRuffCheckHook
  ];

  preCheck = ''
    mypy src/ollama_metrics
  '';

  pythonImportsCheck = [ "ollama_metrics" ];

  meta = {
    description = "Prometheus textfile collector for Ollama state";
    license = lib.licenses.mit;
    mainProgram = "ollama-metrics";
    platforms = lib.platforms.linux;
  };
}
