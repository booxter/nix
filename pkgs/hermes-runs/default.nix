{
  lib,
  python3,
  ruff,
}:
let
  pythonPackages = python3.pkgs;
in
pythonPackages.buildPythonPackage {
  pname = "hermes-runs";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];

  nativeCheckInputs = [
    pythonPackages.mypy
    pythonPackages.pytestCheckHook
    pythonPackages.pytest-cov
    ruff
  ];

  preCheck = ''
    ruff format --check src tests
    ruff check src tests
    mypy src/hermes_runs
  '';

  pythonImportsCheck = [ "hermes_runs" ];

  meta = {
    description = "Small command-line client for the Hermes Agent Runs API";
    license = lib.licenses.mit;
    mainProgram = "hermes-runs";
    platforms = lib.platforms.unix;
  };
}
