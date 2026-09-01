{
  lib,
  python3,
  pythonRuffCheckHook,
}:
let
  pythonPackages = python3.pkgs;
in
pythonPackages.buildPythonApplication {
  pname = "backup-artifact-tools";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];
  dependencies = [ pythonPackages.pydantic ];

  nativeCheckInputs = [
    pythonPackages.mypy
    pythonPackages.pytestCheckHook
    pythonPackages.pytest-cov
    pythonRuffCheckHook
  ];

  preCheck = ''
    mypy src/backup_artifact_tools
  '';

  pythonImportsCheck = [ "backup_artifact_tools" ];

  meta = {
    description = "Create consistent database artifacts for host backups";
    license = lib.licenses.mit;
    mainProgram = "backup-artifact";
    platforms = lib.platforms.linux;
  };
}
