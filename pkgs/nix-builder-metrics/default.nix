{
  atomicFileWrites,
  lib,
  python3,
  ruff,
}:
let
  pythonPackages = python3.pkgs;
in
pythonPackages.buildPythonApplication {
  pname = "nix-builder-metrics";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];
  dependencies = [
    atomicFileWrites
    pythonPackages.prometheus-client
  ];

  nativeCheckInputs = [
    pythonPackages.mypy
    pythonPackages.pytestCheckHook
    pythonPackages.pytest-cov
    ruff
  ];

  preCheck = ''
    ruff format --check src tests
    ruff check src tests
    mypy src/nix_builder_metrics
  '';

  pythonImportsCheck = [ "nix_builder_metrics" ];

  meta = {
    description = "Prometheus textfile metrics for active Nix builder slots";
    license = lib.licenses.mit;
    mainProgram = "nix-builder-metrics";
    platforms = lib.platforms.unix;
  };
}
