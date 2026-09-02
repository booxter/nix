{
  git,
  gitCommandRunner,
  lib,
  openssh,
  python3,
  pythonRuffCheckHook,
}:
let
  pythonPackages = python3.pkgs;
in
pythonPackages.buildPythonApplication {
  pname = "sync-repo";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];

  dependencies = [
    gitCommandRunner
    pythonPackages.pydantic
  ];

  nativeCheckInputs = with pythonPackages; [
    git
    pythonRuffCheckHook
    mypy
    pytestCheckHook
    pytest-cov
  ];

  makeWrapperArgs = [
    "--prefix PATH : ${
      lib.makeBinPath [
        git
        openssh
      ]
    }"
  ];

  preCheck = ''
    mypy src/sync_repo
  '';

  pythonImportsCheck = [ "sync_repo" ];

  meta = {
    description = "Synchronize a personal Git repository on demand";
    license = lib.licenses.mit;
    mainProgram = "sync-repo";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
