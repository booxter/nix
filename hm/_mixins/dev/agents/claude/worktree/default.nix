{
  git,
  lib,
  python3,
  pythonRuffCheckHook,
}:
python3.pkgs.buildPythonApplication {
  pname = "claude-worktree";
  version = "0.1.0";
  pyproject = true;
  src = ./.;

  build-system = [ python3.pkgs.setuptools ];
  dependencies = [ python3.pkgs.pydantic ];
  nativeCheckInputs = with python3.pkgs; [
    git
    pythonRuffCheckHook
    mypy
    pytestCheckHook
    pytest-cov
  ];
  preCheck = ''
    mypy src/claude_worktree
  '';
  pythonImportsCheck = [ "claude_worktree" ];

  makeWrapperArgs = [ "--prefix PATH : ${lib.makeBinPath [ git ]}" ];

  meta = {
    description = "Claude worktree hooks that check out named branches under ~/.claude/worktrees";
    license = lib.licenses.mit;
    mainProgram = "claude-worktree";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
