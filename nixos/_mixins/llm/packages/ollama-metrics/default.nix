{
  atomicFileWrites,
  lib,
  python3,
  ruff,
}:
python3.pkgs.buildPythonApplication {
  pname = "ollama-metrics";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ python3.pkgs.setuptools ];

  dependencies = with python3.pkgs; [
    atomicFileWrites
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
    description = "Export Ollama state as Prometheus textfile metrics";
    license = lib.licenses.mit;
    mainProgram = "ollama-metrics";
    platforms = lib.platforms.linux;
  };
}
