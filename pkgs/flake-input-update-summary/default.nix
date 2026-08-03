{
  lib,
  python3,
  ruff,
}:
let
  pythonPackages = python3.pkgs;
in
pythonPackages.buildPythonApplication {
  pname = "flake-input-update-summary";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];

  dependencies = [ pythonPackages.pydantic ];

  nativeCheckInputs = with pythonPackages; [
    ruff
    mypy
    pytestCheckHook
    pytest-cov
  ];

  preCheck = ''
    ruff format --check src tests
    ruff check src tests
    mypy src/flake_input_update_summary
  '';

  pythonImportsCheck = [ "flake_input_update_summary" ];

  meta = {
    description = "Generate a revision-linked flake input update summary";
    license = lib.licenses.mit;
    mainProgram = "flake-input-update-summary";
    platforms = lib.platforms.unix;
  };
}
