{
  lib,
  python3,
  ruff,
}:
let
  pythonPackages = python3.pkgs;
in
pythonPackages.buildPythonApplication {
  pname = "codex-tools";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];

  dependencies = with pythonPackages; [
    openai
    pydantic
  ];

  nativeCheckInputs = with pythonPackages; [
    ruff
    mypy
    pytestCheckHook
    pytest-cov
  ];

  preCheck = ''
    ruff format --check src tests
    ruff check src tests
    mypy src/codex_tools
  '';

  pythonImportsCheck = [ "codex_tools" ];

  meta = {
    description = "Typed helpers for local Codex account automation";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "codex-usage-status";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
