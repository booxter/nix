{
  git,
  gitCommandRunner,
  lib,
  openssh,
  python3,
  ruff,
}:
let
  pythonPackages = python3.pkgs;
in
pythonPackages.buildPythonApplication {
  pname = "sync-git-mains";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];

  dependencies = [ gitCommandRunner ];

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
    mypy src/sync_git_mains
  '';

  pythonImportsCheck = [ "sync_git_mains" ];

  meta = {
    description = "Discover and fast-forward local Git main branches from origin";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "sync-git-mains";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
