{
  lib,
  python3Packages,
  pythonRuffCheckHook,
}:
python3Packages.buildPythonApplication {
  pname = "codex-launcher";
  version = "0.1.0";
  pyproject = true;
  src = ./.;

  build-system = [ python3Packages.setuptools ];
  dependencies = [ python3Packages.pydantic ];

  nativeCheckInputs = with python3Packages; [
    mypy
    pytestCheckHook
    pytest-cov
    pythonRuffCheckHook
  ];

  preCheck = ''
    mypy src/codex_launcher
  '';

  pythonImportsCheck = [ "codex_launcher" ];

  meta = {
    description = "Prefer an available Codex model";
    license = lib.licenses.mit;
    mainProgram = "codex-launcher";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
