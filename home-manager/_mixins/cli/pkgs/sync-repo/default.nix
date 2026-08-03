{
  git,
  lib,
  openssh,
  python3,
  ruff,
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

  nativeCheckInputs = with pythonPackages; [
    git
    ruff
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
    ruff format --check src tests
    ruff check src tests
    mypy src/sync_repo
  '';

  pythonImportsCheck = [ "sync_repo" ];

  meta = {
    description = "Synchronize a personal Git repository on demand";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "sync-repo";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
