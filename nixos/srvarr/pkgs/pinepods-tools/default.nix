{
  lib,
  python3,
  ruff,
}:
let
  pythonPackages = python3.pkgs;
in
pythonPackages.buildPythonApplication {
  pname = "pinepods-tools";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ pythonPackages.setuptools ];
  dependencies = with pythonPackages; [
    httpx
    psycopg
    pydantic
  ];

  nativeCheckInputs = with pythonPackages; [
    mypy
    pytestCheckHook
    pytest-cov
    ruff
  ];

  preCheck = ''
    ruff format --check src tests
    ruff check src tests
    mypy src/pinepods_tools
  '';

  pythonImportsCheck = [ "pinepods_tools" ];

  meta = {
    description = "Bootstrap and back up the srvarr PinePods service";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ booxter ];
    platforms = lib.platforms.linux;
  };
}
