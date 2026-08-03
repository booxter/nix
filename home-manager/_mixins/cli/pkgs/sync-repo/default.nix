{
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

  dependencies = [
    pythonPackages.dulwich
    # TODO(nixpkgs): Dulwich's rebase support imports merge3, but the nixpkgs
    # package does not propagate that runtime dependency yet.
    pythonPackages.merge3
  ];

  nativeCheckInputs = with pythonPackages; [
    ruff
    mypy
    pytestCheckHook
    pytest-cov
  ];

  makeWrapperArgs = [
    "--prefix PATH : ${lib.makeBinPath [ openssh ]}"
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
