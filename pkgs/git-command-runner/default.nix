{
  git,
  lib,
  python,
  ruff,
}:
let
  pythonPackages = python.pkgs;
in
pythonPackages.buildPythonPackage {
  pname = "git-command-runner";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];

  nativeCheckInputs = with pythonPackages; [
    git
    ruff
    mypy
    pytestCheckHook
    pytest-cov
  ];

  preCheck = ''
    ruff format --check src tests
    ruff check src tests
    mypy src/git_command_runner
  '';

  pythonImportsCheck = [ "git_command_runner" ];

  meta = {
    description = "Typed subprocess runner for internal Git applications";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
