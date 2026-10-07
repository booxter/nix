{
  lib,
  mariadb,
  python3,
  pythonRuffCheckHook,
}:
let
  pythonPackages = python3.pkgs;
in
pythonPackages.buildPythonApplication {
  pname = "romm-tools";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];
  dependencies = [
    pythonPackages.mariadb
    pythonPackages.pydantic
    pythonPackages.sqlalchemy
  ];

  nativeCheckInputs = [
    mariadb
    pythonPackages.mypy
    pythonPackages.pytestCheckHook
    pythonPackages.pytest-cov
    pythonRuffCheckHook
  ];

  preCheck = ''
    mypy src/romm_tools
  '';

  pythonImportsCheck = [ "romm_tools" ];

  meta = {
    description = "Host integration tools for the RomM service";
    license = lib.licenses.mit;
    mainProgram = "romm-db-init";
    platforms = lib.platforms.linux;
  };
}
