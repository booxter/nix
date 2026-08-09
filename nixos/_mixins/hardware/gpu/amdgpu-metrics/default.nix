{
  amdgpu_top,
  lib,
  makeWrapper,
  python3,
}:
python3.pkgs.buildPythonApplication {
  pname = "amdgpu-metrics";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ python3.pkgs.setuptools ];

  dependencies = with python3.pkgs; [
    prometheus-client
    pydantic
  ];

  nativeBuildInputs = [ makeWrapper ];

  nativeCheckInputs = with python3.pkgs; [
    mypy
    pytestCheckHook
    pytest-cov
    ruff
  ];

  preCheck = ''
    ruff format --check src tests
    ruff check src tests
    mypy src/amdgpu_metrics
  '';

  postFixup = ''
    wrapProgram "$out/bin/amdgpu-metrics" \
      --set-default AMDGPU_METRICS_AMDGPU_TOP ${lib.getExe amdgpu_top}
  '';

  pythonImportsCheck = [ "amdgpu_metrics" ];

  meta = {
    description = "Export AMD GPU state as Prometheus textfile metrics";
    license = lib.licenses.mit;
    mainProgram = "amdgpu-metrics";
    platforms = lib.platforms.linux;
  };
}
