{
  lib,
  python3,
  pythonRuffCheckHook,
}:
python3.pkgs.buildPythonApplication {
  pname = "claude-statusline";
  version = "0.1.0";
  pyproject = true;
  src = ./.;

  build-system = [ python3.pkgs.setuptools ];
  dependencies = [ python3.pkgs.pydantic ];
  nativeCheckInputs = with python3.pkgs; [
    pythonRuffCheckHook
    mypy
    pytestCheckHook
    pytest-cov
  ];
  preCheck = ''
    mypy src/claude_statusline
  '';
  pythonImportsCheck = [ "claude_statusline" ];

  meta = {
    description = "Claude status line with context and session token counts";
    license = lib.licenses.mit;
    mainProgram = "claude-statusline";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
