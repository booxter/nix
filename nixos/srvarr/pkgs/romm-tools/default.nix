{
  lib,
  mariadb,
  python3,
  ruff,
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
    pythonPackages.podman
    pythonPackages.pydantic
    pythonPackages.requests
    pythonPackages.sqlalchemy
  ];

  nativeCheckInputs = [
    mariadb
    pythonPackages.mypy
    pythonPackages.pytestCheckHook
    pythonPackages.pytest-cov
    # podman exposes requests response types without propagating their stubs;
    # fix this in nixpkgs' podman dependency closure instead of keeping it here.
    pythonPackages.types-requests
    ruff
  ];

  preCheck = ''
    ruff format --check src tests
    ruff check src tests
    mypy src/romm_tools
  '';

  pythonImportsCheck = [ "romm_tools" ];

  meta = {
    description = "Host integration tools for the srvarr RomM service";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    mainProgram = "romm-db-init";
    platforms = lib.platforms.linux;
  };
}
