{
  git,
  lib,
  python,
  pythonRuffCheckHook,
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
    pythonRuffCheckHook
    mypy
    pytestCheckHook
    pytest-cov
  ];

  preCheck = ''
    mypy src/git_command_runner
  '';

  pythonImportsCheck = [ "git_command_runner" ];

  meta = {
    description = "Typed subprocess runner for internal Git applications";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
