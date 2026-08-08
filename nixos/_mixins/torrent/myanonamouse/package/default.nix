{
  atomicFileWrites,
  lib,
  python3,
  ruff,
}:
let
  pythonPackages = python3.pkgs;
in
pythonPackages.buildPythonApplication {
  pname = "myanonamouse-ip-updater";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];
  dependencies = [
    atomicFileWrites
    pythonPackages.pydantic
  ];

  nativeCheckInputs = [
    pythonPackages.mypy
    pythonPackages.pytestCheckHook
    pythonPackages.pytest-cov
    ruff
  ];

  preCheck = ''
    ruff format --check src tests
    ruff check src tests
    mypy src/myanonamouse_ip_updater
  '';

  pythonImportsCheck = [ "myanonamouse_ip_updater" ];

  meta = {
    description = "Update the MyAnonamouse dynamic seedbox address";
    license = lib.licenses.mit;
    mainProgram = "myanonamouse-ip-update";
    platforms = lib.platforms.linux;
  };
}
