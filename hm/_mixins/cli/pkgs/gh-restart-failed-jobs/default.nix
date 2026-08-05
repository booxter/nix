{
  gh,
  lib,
  python3,
  ruff,
}:
let
  pythonPackages = python3.pkgs;
in
pythonPackages.buildPythonApplication {
  pname = "gh-restart-failed-jobs";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];

  dependencies = [ pythonPackages.pygithub ];

  nativeCheckInputs = with pythonPackages; [
    ruff
    mypy
    pytestCheckHook
    pytest-cov
  ];

  makeWrapperArgs = [
    "--prefix PATH : ${lib.makeBinPath [ gh ]}"
  ];

  preCheck = ''
    ruff format --check src tests
    ruff check src tests
    mypy src/gh_restart_failed_jobs
  '';

  pythonImportsCheck = [ "gh_restart_failed_jobs" ];

  meta = {
    description = "Restart failed GitHub Actions jobs for a pull request";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "gh-restart-failed-jobs";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
