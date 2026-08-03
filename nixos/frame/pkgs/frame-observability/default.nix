{
  lib,
  python3,
}:
python3.pkgs.buildPythonApplication {
  pname = "frame-observability";
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
    mypy src/frame_observability
  '';

  pythonImportsCheck = [ "frame_observability" ];

  meta = {
    description = "Typed Prometheus textfile collectors for frame";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "frame-ollama-metrics";
    platforms = lib.platforms.linux;
  };
}
